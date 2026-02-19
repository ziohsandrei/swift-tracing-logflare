# swift-tracing-logflare

A Swift library that provides a [Logflare](https://logflare.app) tracer implementation for [swift-tracing](https://github.com/grdsdev/swift-tracing).

## Overview

This library allows you to export distributed tracing spans from your Swift applications to Logflare, providing real-time observability and analytics for your application's performance and behavior.

## Installation

Add the following to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/grdsdev/swift-tracing-logflare.git", from: "0.1.0")
]
```

Then add the product to your target:

```swift
.target(
  name: "YourTarget",
  dependencies: [
    .product(name: "TracingLogflare", package: "swift-tracing-logflare")
  ]
)
```

## Usage

### Basic Setup

```swift
import Tracing
import TracingLogflare

let configuration = LogflareConfiguration(
  apiKey: "your-api-key",
  sourceToken: "your-source-token"
)

let tracer = LogflareTracer(configuration: configuration)
InstrumentationSystem.bootstrap(tracer)
```

### Configuration Options

```swift
let configuration = LogflareConfiguration(
  apiKey: "your-api-key",
  sourceToken: "your-source-token",
  endpoint: URL(string: "https://api.logflare.app")!, // Custom endpoint
  batchSize: 10,                                       // Spans per batch
  flushInterval: 10                                    // Seconds between flushes
)
```

### Creating Spans

```swift
// Start a span
let span = tracer.startSpan("operation-name")

// Add attributes
span.attributes["user.id"] = "123"
span.attributes["http.method"] = "GET"

// Record errors
do {
  try somethingThatMightFail()
} catch {
  span.recordError(error)
}

// End the span
span.end()
```

### Using with async/await

```swift
func fetchData() async throws -> Data {
  let span = tracer.startSpan("fetch-data")
  defer { span.end() }

  span.attributes["http.url"] = "https://api.example.com/data"

  do {
    let data = try await performRequest()
    span.attributes["http.status_code"] = 200
    return data
  } catch {
    span.recordError(error)
    throw error
  }
}
```

### Manual Flush

```swift
// Force immediate export of buffered spans
tracer.forceFlush()
```

## Features

- Automatic batching and periodic flushing of spans
- Support for parent-child span relationships
- HTTP request/response span formatting
- Error recording and status tracking
- Thread-safe span buffering
- Automatic cleanup on deinit

## Requirements

- iOS 13.0+ / macOS 10.15+ / tvOS 13.0+ / watchOS 6.0+
- Swift 5.9+

## Dependencies

- [swift-tracing](https://github.com/grdsdev/swift-tracing)
- [swift-concurrency-extras](https://github.com/pointfreeco/swift-concurrency-extras)

## License

This library is released under the MIT license. See LICENSE for details.
