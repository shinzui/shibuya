let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/4412469f2960b8faa48c123451bf90c0d3400db3/package.dhall
        sha256:2e416c2d8c28c0b3b217cab47cc6d9e8bb9bec34b87d476edbb0d6d0863d1401

let emptyRuntime = { deployable = False, exposesApi = False }

let emptyDeps = [] : List Schema.Dependency

let emptyDocs = [] : List Schema.DocRef

let emptyConfig = [] : List Schema.ConfigItem

in  { project =
      { name = "shibuya"
      , namespace = "shinzui"
      , type = Schema.PackageType.Library
      , description = Some
          "Supervised queue processing framework for Haskell, inspired by Broadway (Elixir)"
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Active
      , domains = [ "concurrency", "queue-processing" ]
      , owners = [ "shinzui" ]
      , origin = Schema.Origin.Own
      }
    , repos =
      [ { name = "shibuya"
        , github = Some "shinzui/shibuya"
        , gitlab = None Text
        , git = None Text
        , localPath = Some "."
        }
      ]
    , packages =
      [ { name = "shibuya-core"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shibuya-core"
        , description = Some
            "Core framework: supervision, backpressure, ack semantics, and tracing"
        , visibility = Schema.Visibility.Public
        , runtime = emptyRuntime
        , dependencies =
          [ Schema.Dependency.ByName "effectful/effectful"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        }
      , { name = "shibuya-metrics"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shibuya-metrics"
        , description = Some
            "HTTP/JSON, Prometheus, and WebSocket metrics endpoints"
        , visibility = Schema.Visibility.Public
        , runtime = { deployable = False, exposesApi = True }
        , dependencies =
          [ Schema.Dependency.ByName "effectful/effectful"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        }
      , { name = "shibuya-pgmq-adapter"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shibuya-pgmq-adapter"
        , description = Some
            "PGMQ adapter with visibility timeout leasing, retry handling, and DLQ support"
        , visibility = Schema.Visibility.Public
        , runtime = emptyRuntime
        , dependencies =
          [ Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "shinzui/pgmq-hs"
          , Schema.Dependency.ByName "hasql/hasql"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        }
      , { name = "shibuya-example"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "shibuya-example"
        , description = Some
            "Example demonstrating multi-processor setup with mock adapter"
        , visibility = Schema.Visibility.Internal
        , runtime = { deployable = True, exposesApi = False }
        , dependencies = emptyDeps
        , docs = emptyDocs
        , config = emptyConfig
        }
      , { name = "shibuya-pgmq-example"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "shibuya-pgmq-example"
        , description = Some
            "Real-world example with PGMQ, OpenTelemetry tracing, and Prometheus metrics"
        , visibility = Schema.Visibility.Internal
        , runtime = { deployable = True, exposesApi = True }
        , dependencies = emptyDeps
        , docs = emptyDocs
        , config = emptyConfig
        }
      , { name = "shibuya-core-bench"
        , type = Schema.PackageType.Other "Benchmark"
        , language = Schema.Language.Haskell
        , path = Some "shibuya-core-bench"
        , description = Some
            "Benchmarks for framework overhead vs pure streamly"
        , visibility = Schema.Visibility.Internal
        , runtime = emptyRuntime
        , dependencies = emptyDeps
        , docs = emptyDocs
        , config = emptyConfig
        }
      , { name = "shibuya-pgmq-adapter-bench"
        , type = Schema.PackageType.Other "Benchmark"
        , language = Schema.Language.Haskell
        , path = Some "shibuya-pgmq-adapter-bench"
        , description = Some
            "Throughput and concurrency benchmarks for the PGMQ adapter"
        , visibility = Schema.Visibility.Internal
        , runtime = emptyRuntime
        , dependencies = emptyDeps
        , docs = emptyDocs
        , config = emptyConfig
        }
      ]
    , bundles =
      [ { name = "shibuya-full"
        , description = Some
            "Complete Shibuya stack with PGMQ adapter and metrics"
        , packages =
          [ "shibuya-core"
          , "shibuya-metrics"
          , "shibuya-pgmq-adapter"
          ]
        , primary = "shibuya-core"
        }
      ]
    , dependencies =
      [ "effectful/effectful"
      , "shinzui/pgmq-hs"
      , "hasql/hasql"
      ]
    , apis = [] : List Schema.Api
    , agents =
      [ { role = "framework-dev"
        , description = Some
            "Core framework development: supervision, processing, and ack semantics"
        , includePaths =
          [ "shibuya-core/src/**"
          , "shibuya-core/test/**"
          ]
        , excludePaths =
          [ "dist-newstyle/**"
          ]
        , relatedPackages =
          [ "shibuya-core"
          ]
        }
      , { role = "adapter-dev"
        , description = Some
            "Queue adapter development: PGMQ integration and benchmarks"
        , includePaths =
          [ "shibuya-pgmq-adapter/src/**"
          , "shibuya-pgmq-adapter-bench/**"
          ]
        , excludePaths =
          [ "dist-newstyle/**"
          ]
        , relatedPackages =
          [ "shibuya-pgmq-adapter"
          , "shibuya-pgmq-adapter-bench"
          ]
        }
      ]
    , standards = [] : List Text
    , docs =
      [ { key = "architecture"
        , kind = Schema.DocKind.Reference
        , audience = Schema.DocAudience.Internal
        , description = Some
            "Architecture docs: message flow, core types, metrics"
        , location = Schema.DocLocation.LocalDir "docs/architecture"
        }
      , { key = "readme"
        , kind = Schema.DocKind.Guide
        , audience = Schema.DocAudience.User
        , description = Some "Project README with quickstart"
        , location = Schema.DocLocation.LocalFile "README.md"
        }
      , { key = "changelog"
        , kind = Schema.DocKind.Notes
        , audience = Schema.DocAudience.User
        , description = Some "Release changelog"
        , location = Schema.DocLocation.LocalFile "CHANGELOG.md"
        }
      , { key = "hackage"
        , kind = Schema.DocKind.Reference
        , audience = Schema.DocAudience.API
        , description = Some "Hackage package page"
        , location =
            Schema.DocLocation.Url
              "https://hackage.haskell.org/package/shibuya-core"
        }
      ]
    }
