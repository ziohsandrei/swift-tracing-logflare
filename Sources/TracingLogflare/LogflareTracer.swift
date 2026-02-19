//
//  LogflareTracer.swift
//  TracingLogflare
//

import ConcurrencyExtras
import Foundation
import Tracing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Configuration for Logflare integration.
public struct LogflareConfiguration: Sendable {
  public let apiKey: String
  public let sourceToken: String
  public let endpoint: URL
  public let batchSize: Int
  public let flushInterval: TimeInterval

  public init(
    apiKey: String,
    sourceToken: String,
    endpoint: URL = URL(string: "https://api.logflare.app")!,
    batchSize: Int = 10,
    flushInterval: TimeInterval = 10
  ) {
    self.apiKey = apiKey
    self.sourceToken = sourceToken
    self.endpoint = endpoint
    self.batchSize = batchSize
    self.flushInterval = flushInterval
  }
}

/// A tracer that exports spans to Logflare.
public final class LogflareTracer: Tracer, @unchecked Sendable {
  public typealias Span = LogflareSpan

  private let configuration: LogflareConfiguration
  private let urlSession: URLSession
  private let mutableState = LockIsolated(MutableState())

  private struct MutableState {
    var spanBuffer: [CompletedSpan] = []
    var flushTimer: Timer?
  }

  public init(
    configuration: LogflareConfiguration,
    urlSession: URLSession = .shared
  ) {
    self.configuration = configuration
    self.urlSession = urlSession
    startPeriodicFlush()
  }

  public func startSpan(
    _ operationName: String,
    context: SpanContext?,
    ofKind kind: SpanKind,
    at instant: (any TracerInstant)?
  ) -> LogflareSpan {
    let spanContext: SpanContext
    if let context {
      spanContext = context.makeChild(spanID: UUID().uuidString)
    } else {
      spanContext = SpanContext(
        traceID: UUID().uuidString,
        spanID: UUID().uuidString
      )
    }

    return LogflareSpan(
      operationName: operationName,
      context: spanContext,
      kind: kind,
      onEnd: { [weak self] completedSpan in
        self?.recordSpan(completedSpan)
      }
    )
  }

  private func forceFlush(mutableState: inout MutableState) {
    let spans = mutableState.spanBuffer
    mutableState.spanBuffer.removeAll()

    guard !spans.isEmpty else { return }

    Task {
      do {
        try await export(spans)
      } catch {
        print("[Logflare] Failed to export spans: \(error)")
      }
    }
  }

  public func forceFlush() {
    mutableState.withValue {
      forceFlush(mutableState: &$0)
    }
  }

  private func startPeriodicFlush() {
    mutableState.withValue {
      $0.flushTimer =
        Timer.scheduledTimer(
          withTimeInterval: configuration.flushInterval,
          repeats: true
        ) { [weak self] _ in
          self?.forceFlush()
        }
    }
  }

  private func recordSpan(_ span: CompletedSpan) {
    let shouldFlush = mutableState.withValue {
      $0.spanBuffer.append(span)
      return $0.spanBuffer.count >= configuration.batchSize
    }

    if shouldFlush {
      forceFlush()
    }
  }

  private func export(_ spans: [CompletedSpan]) async throws {
    let logs = spans.map { span -> [String: Any] in
      var metadata: [String: Any] = [
        "trace_id": span.context.traceID,
        "span_id": span.context.spanID,
        "operation": span.operationName,
        "kind": String(describing: span.kind),
        "duration_ms": span.durationMs,
        "status": span.status.map { String(describing: $0) } ?? "ok",
      ]

      if let parentSpanID = span.context.parentSpanID {
        metadata["parent_span_id"] = parentSpanID
      }

      if !span.attributes.isEmpty {
        var attrs: [String: String] = [:]
        for (key, value) in span.attributes {
          attrs[key] = value.stringValue
        }
        metadata["attributes"] = attrs
      }

      if let error = span.error {
        metadata["error"] = String(describing: error)
      }

      let message = formatMessage(span)

      return [
        "message": message,
        "metadata": metadata,
      ]
    }

    let payload: [String: Any] = ["batch": logs]
    let jsonData = try JSONSerialization.data(withJSONObject: payload)

    var urlComponents = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: true)!
    urlComponents.path = "/api/logs"
    urlComponents.queryItems = [
      URLQueryItem(name: "source", value: configuration.sourceToken)
    ]

    var request = URLRequest(url: urlComponents.url!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = jsonData

    let (_, response) = try await urlSession.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw LogflareError.invalidResponse
    }

    if httpResponse.statusCode >= 500 {
      throw LogflareError.serverError(statusCode: httpResponse.statusCode)
    } else if httpResponse.statusCode >= 400 {
      throw LogflareError.clientError(statusCode: httpResponse.statusCode)
    }
  }

  private func formatMessage(_ span: CompletedSpan) -> String {
    if let method = span.attributes["http.method"]?.stringValue,
      let url = span.attributes["http.url"]?.stringValue,
      let status = span.attributes["http.status_code"]?.stringValue
    {
      return "HTTP \(method) \(url) - \(status) in \(span.durationMs)ms"
    }

    if span.operationName.hasPrefix("realtime.") {
      return "\(span.operationName) in \(span.durationMs)ms"
    }

    return "\(span.operationName) (\(span.durationMs)ms)"
  }

  deinit {
    mutableState.withValue { state in
      state.flushTimer?.invalidate()
      state.flushTimer = nil

      // Flush remaining spans synchronously
      let spans = state.spanBuffer
      state.spanBuffer.removeAll()

      guard !spans.isEmpty else { return }

      // Note: We cannot perform async operations in deinit
      // Remaining spans will be lost if not flushed before deallocation
    }
  }
}

private enum LogflareError: Error {
  case invalidResponse
  case serverError(statusCode: Int)
  case clientError(statusCode: Int)
}

// MARK: - Span Implementation

public final class LogflareSpan: SpanProtocol, @unchecked Sendable {
  public let context: SpanContext
  private let kind: SpanKind
  private let onEnd: @Sendable (CompletedSpan) -> Void
  private let startTime: Date

  private struct MutableState {
    var operationName: String
    var attributes: SpanAttributes = SpanAttributes()
    var status: SpanStatus?
    var error: (any Error)?
    var isRecording = true
  }

  private let mutableState: LockIsolated<MutableState>

  fileprivate init(
    operationName: String,
    context: SpanContext,
    kind: SpanKind,
    onEnd: @escaping @Sendable (CompletedSpan) -> Void
  ) {
    self.context = context
    self.kind = kind
    self.startTime = Date()
    self.onEnd = onEnd
    self.mutableState = LockIsolated(
      MutableState(operationName: operationName)
    )
  }

  public var operationName: String {
    mutableState.withValue { $0.operationName }
  }

  public var attributes: SpanAttributes {
    get { mutableState.withValue { $0.attributes } }
    set { mutableState.withValue { $0.attributes = newValue } }
  }

  public var isRecording: Bool {
    mutableState.withValue { $0.isRecording }
  }

  public func setStatus(_ status: SpanStatus) {
    mutableState.withValue { $0.status = status }
  }

  public func addEvent(_ event: SpanEvent) {
    // Events not currently exported to Logflare
  }

  public func recordError(
    _ error: any Error,
    attributes: SpanAttributes,
    at instant: (any TracerInstant)?
  ) {
    mutableState.withValue {
      $0.error = error
      $0.status = .error(message: String(describing: error))
      $0.attributes.merge(attributes)
    }
  }

  public func addLink(_ context: SpanContext) {
    // Links not currently supported
  }

  public func end(at instant: (any TracerInstant)?) {
    let completed = mutableState.withValue { state -> CompletedSpan? in
      guard state.isRecording else { return nil }
      state.isRecording = false

      let endTime = Date()
      let durationMs = Int64(endTime.timeIntervalSince(startTime) * 1000)

      return CompletedSpan(
        operationName: state.operationName,
        context: context,
        kind: kind,
        status: state.status,
        durationMs: durationMs,
        attributes: state.attributes,
        error: state.error
      )
    }

    if let completed {
      onEnd(completed)
    }
  }
}

// MARK: - Completed Span

private struct CompletedSpan: Sendable {
  let operationName: String
  let context: SpanContext
  let kind: SpanKind
  let status: SpanStatus?
  let durationMs: Int64
  let attributes: SpanAttributes
  let error: (any Error)?
}

// MARK: - SpanAttribute Extension

extension SpanAttribute {
  fileprivate var stringValue: String {
    switch self {
    case .int32(let value):
      return String(value)
    case .int64(let value):
      return String(value)
    case .double(let value):
      return String(value)
    case .string(let value):
      return value
    case .bool(let value):
      return String(value)
    case .int32Array(let values):
      return values.map { String($0) }.joined(separator: ",")
    case .int64Array(let values):
      return values.map { String($0) }.joined(separator: ",")
    case .doubleArray(let values):
      return values.map { String($0) }.joined(separator: ",")
    case .stringArray(let values):
      return values.joined(separator: ",")
    case .boolArray(let values):
      return values.map { String($0) }.joined(separator: ",")
    }
  }
}
