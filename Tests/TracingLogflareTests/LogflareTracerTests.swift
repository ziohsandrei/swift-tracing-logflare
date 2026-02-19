//
//  LogflareTracerTests.swift
//  TracingLogflareTests
//

import Foundation
import Testing
import Tracing
@testable import TracingLogflare

@Suite("LogflareTracer Tests")
struct LogflareTracerTests {

  @Test("Creates configuration with default values")
  func testConfigurationDefaults() {
    let config = LogflareConfiguration(
      apiKey: "test-key",
      sourceToken: "test-token"
    )

    #expect(config.apiKey == "test-key")
    #expect(config.sourceToken == "test-token")
    #expect(config.endpoint.absoluteString == "https://api.logflare.app")
    #expect(config.batchSize == 10)
    #expect(config.flushInterval == 10)
  }

  @Test("Creates configuration with custom values")
  func testConfigurationCustom() {
    let customEndpoint = URL(string: "https://custom.logflare.app")!
    let config = LogflareConfiguration(
      apiKey: "test-key",
      sourceToken: "test-token",
      endpoint: customEndpoint,
      batchSize: 20,
      flushInterval: 5
    )

    #expect(config.endpoint == customEndpoint)
    #expect(config.batchSize == 20)
    #expect(config.flushInterval == 5)
  }

  @Test("Creates tracer instance")
  func testTracerCreation() {
    let config = LogflareConfiguration(
      apiKey: "test-key",
      sourceToken: "test-token"
    )

    let _ = LogflareTracer(configuration: config)
    // Successfully creating a tracer is sufficient
  }

  @Test("Starts span without context")
  func testStartSpanWithoutContext() {
    let config = LogflareConfiguration(
      apiKey: "test-key",
      sourceToken: "test-token"
    )
    let tracer = LogflareTracer(configuration: config)

    let span = tracer.startSpan("test-operation", context: nil, ofKind: .client, at: nil)

    #expect(span.operationName == "test-operation")
    #expect(span.context.traceID.isEmpty == false)
    #expect(span.context.spanID.isEmpty == false)
    #expect(span.isRecording == true)
  }

  @Test("Starts span with parent context")
  func testStartSpanWithContext() {
    let config = LogflareConfiguration(
      apiKey: "test-key",
      sourceToken: "test-token"
    )
    let tracer = LogflareTracer(configuration: config)

    let parentSpan = tracer.startSpan("parent", context: nil, ofKind: .server, at: nil)
    let childSpan = tracer.startSpan("child", context: parentSpan.context, ofKind: .client, at: nil)

    #expect(childSpan.context.traceID == parentSpan.context.traceID)
    #expect(childSpan.context.spanID != parentSpan.context.spanID)
    #expect(childSpan.context.parentSpanID == parentSpan.context.spanID)
  }

  @Test("Sets span attributes")
  func testSpanAttributes() {
    let config = LogflareConfiguration(
      apiKey: "test-key",
      sourceToken: "test-token"
    )
    let tracer = LogflareTracer(configuration: config)
    let span = tracer.startSpan("test", context: nil, ofKind: .client, at: nil)

    span.attributes["key1"] = "value1"
    span.attributes["key2"] = .int64(42)

    #expect(span.attributes["key1"] != nil)
    #expect(span.attributes["key2"] != nil)
  }

  @Test("Records span error")
  func testRecordError() {
    let config = LogflareConfiguration(
      apiKey: "test-key",
      sourceToken: "test-token"
    )
    let tracer = LogflareTracer(configuration: config)
    let span = tracer.startSpan("test", context: nil, ofKind: .client, at: nil)

    struct TestError: Error {}
    let error = TestError()

    span.recordError(error, attributes: [:], at: nil)

    // Span should still be recording after error
    #expect(span.isRecording == true)
  }

  @Test("Ends span")
  func testEndSpan() {
    let config = LogflareConfiguration(
      apiKey: "test-key",
      sourceToken: "test-token"
    )
    let tracer = LogflareTracer(configuration: config)
    let span = tracer.startSpan("test", context: nil, ofKind: .client, at: nil)

    #expect(span.isRecording == true)

    span.end(at: nil)

    #expect(span.isRecording == false)
  }

  @Test("Multiple spans can be created")
  func testMultipleSpans() {
    let config = LogflareConfiguration(
      apiKey: "test-key",
      sourceToken: "test-token"
    )
    let tracer = LogflareTracer(configuration: config)

    let span1 = tracer.startSpan("operation1", context: nil, ofKind: .client, at: nil)
    let span2 = tracer.startSpan("operation2", context: nil, ofKind: .server, at: nil)

    #expect(span1.operationName == "operation1")
    #expect(span2.operationName == "operation2")
    #expect(span1.context.spanID != span2.context.spanID)
  }
}
