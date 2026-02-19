//
//  LogflareTracer.swift
//  TracingLogflare
//

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
  private let lock = NSLock()
  private var spanBuffer: [CompletedSpan] = []
  private var flushTimer: Timer?

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

  public func forceFlush() {
    lock.lock()
    let spans = spanBuffer
    spanBuffer.removeAll()
    lock.unlock()

    guard !spans.isEmpty else { return }

    Task {
      do {
        try await export(spans)
      } catch {
        print("[Logflare] Failed to export spans: \(error)")
      }
    }
  }

  private func startPeriodicFlush() {
    lock.lock()
    flushTimer = Timer.scheduledTimer(
      withTimeInterval: configuration.flushInterval,
      repeats: true
    ) { [weak self] _ in
      self?.forceFlush()
    }
    lock.unlock()
  }

  private func recordSpan(_ span: CompletedSpan) {
    lock.lock()
    spanBuffer.append(span)
    let shouldFlush = spanBuffer.count >= configuration.batchSize
    lock.unlock()

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
    lock.lock()
    flushTimer?.invalidate()
    flushTimer = nil
    spanBuffer.removeAll()
    lock.unlock()

    // Note: We cannot perform async operations in deinit
    // Remaining spans will be lost if not flushed before deallocation
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
  private let lock = NSLock()

  private var _operationName: String
  private var _attributes: SpanAttributes = SpanAttributes()
  private var _status: SpanStatus?
  private var _error: (any Error)?
  private var _isRecording = true

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
    self._operationName = operationName
  }

  public var operationName: String {
    lock.lock()
    defer { lock.unlock() }
    return _operationName
  }

  public var attributes: SpanAttributes {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _attributes
    }
    set {
      lock.lock()
      _attributes = newValue
      lock.unlock()
    }
  }

  public var isRecording: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _isRecording
  }

  public func setStatus(_ status: SpanStatus) {
    lock.lock()
    _status = status
    lock.unlock()
  }

  public func addEvent(_ event: SpanEvent) {
    // Events not currently exported to Logflare
  }

  public func recordError(
    _ error: any Error,
    attributes: SpanAttributes,
    at instant: (any TracerInstant)?
  ) {
    lock.lock()
    _error = error
    _status = .error(message: String(describing: error))
    _attributes.merge(attributes)
    lock.unlock()
  }

  public func addLink(_ context: SpanContext) {
    // Links not currently supported
  }

  public func end(at instant: (any TracerInstant)?) {
    lock.lock()
    guard _isRecording else {
      lock.unlock()
      return
    }
    _isRecording = false

    let endTime = Date()
    let durationMs = Int64(endTime.timeIntervalSince(startTime) * 1000)

    let completed = CompletedSpan(
      operationName: _operationName,
      context: context,
      kind: kind,
      status: _status,
      durationMs: durationMs,
      attributes: _attributes,
      error: _error
    )
    lock.unlock()

    onEnd(completed)
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
