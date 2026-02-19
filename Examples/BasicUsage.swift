import Foundation
import Tracing
import TracingLogflare

// MARK: - Basic Usage Example

func setupLogflareTracing() {
  let configuration = LogflareConfiguration(
    apiKey: "your-logflare-api-key",
    sourceToken: "your-source-token",
    batchSize: 10,
    flushInterval: 10
  )

  let tracer = LogflareTracer(configuration: configuration)
  InstrumentationSystem.bootstrap(tracer)
}

// MARK: - HTTP Request Example

func makeHTTPRequest() async throws {
  let tracer = InstrumentationSystem.tracer
  let span = tracer.startSpan("http.request")

  span.attributes["http.method"] = "GET"
  span.attributes["http.url"] = "https://api.example.com/users"

  defer {
    span.end()
  }

  do {
    // Simulate HTTP request
    try await Task.sleep(nanoseconds: 100_000_000)

    span.attributes["http.status_code"] = .int64(200)
    span.setStatus(.ok)
  } catch {
    span.attributes["http.status_code"] = .int64(500)
    span.recordError(error, attributes: [:], at: nil)
    throw error
  }
}

// MARK: - Nested Spans Example

func processOrder() async throws {
  let tracer = InstrumentationSystem.tracer
  let parentSpan = tracer.startSpan("process.order")

  parentSpan.attributes["order.id"] = "12345"

  defer {
    parentSpan.end()
  }

  // Child span for validation
  let validationSpan = tracer.startSpan(
    "validate.order",
    context: parentSpan.context,
    ofKind: .internal,
    at: nil
  )
  try await validateOrder()
  validationSpan.end()

  // Child span for payment
  let paymentSpan = tracer.startSpan(
    "process.payment",
    context: parentSpan.context,
    ofKind: .client,
    at: nil
  )
  try await processPayment()
  paymentSpan.end()

  parentSpan.setStatus(.ok)
}

func validateOrder() async throws {
  try await Task.sleep(nanoseconds: 50_000_000)
}

func processPayment() async throws {
  try await Task.sleep(nanoseconds: 100_000_000)
}

// MARK: - Database Operation Example

func queryDatabase() async throws {
  let tracer = InstrumentationSystem.tracer
  let span = tracer.startSpan("db.query")

  span.attributes["db.system"] = "postgresql"
  span.attributes["db.operation"] = "SELECT"
  span.attributes["db.statement"] = "SELECT * FROM users WHERE id = $1"

  defer {
    span.end()
  }

  do {
    // Simulate database query
    try await Task.sleep(nanoseconds: 150_000_000)
    span.attributes["db.rows_affected"] = .int64(1)
    span.setStatus(.ok)
  } catch {
    span.recordError(error, attributes: [:], at: nil)
    throw error
  }
}

// MARK: - Run Examples

@main
struct ExampleRunner {
  static func main() async {
    setupLogflareTracing()

    do {
      print("Making HTTP request...")
      try await makeHTTPRequest()

      print("Processing order...")
      try await processOrder()

      print("Querying database...")
      try await queryDatabase()

      // Force flush before exiting
      if let tracer = InstrumentationSystem.tracer as? LogflareTracer {
        tracer.forceFlush()
      }

      // Give time for async exports to complete
      try await Task.sleep(nanoseconds: 1_000_000_000)

      print("Examples completed!")
    } catch {
      print("Error: \(error)")
    }
  }
}
