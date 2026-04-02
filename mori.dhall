let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/8415b4b8a746a84eecf982f0f1d7194368bf7b54/package.dhall
        sha256:d19ae156d6c357d982a1aea0f1b6ba1f01d76d2d848545b150db75ed4c39a8a9

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
        , lifecycle = None Schema.Lifecycle
        , visibility = Schema.Visibility.Public
        , runtime = emptyRuntime
        , runtimeEnvironment = None Schema.RuntimeEnvironment
        , dependencies =
          [ Schema.Dependency.ByName "effectful/effectful"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        , apiSource = None Schema.ApiSource
        }
      , { name = "shibuya-metrics"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shibuya-metrics"
        , description = Some
            "HTTP/JSON, Prometheus, and WebSocket metrics endpoints"
        , lifecycle = None Schema.Lifecycle
        , visibility = Schema.Visibility.Public
        , runtime = { deployable = False, exposesApi = True }
        , runtimeEnvironment = None Schema.RuntimeEnvironment
        , dependencies =
          [ Schema.Dependency.ByName "effectful/effectful"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        , apiSource = None Schema.ApiSource
        }
      , { name = "shibuya-pgmq-adapter"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shibuya-pgmq-adapter"
        , description = Some
            "PGMQ adapter with visibility timeout leasing, retry handling, and DLQ support"
        , lifecycle = None Schema.Lifecycle
        , visibility = Schema.Visibility.Public
        , runtime = emptyRuntime
        , runtimeEnvironment = None Schema.RuntimeEnvironment
        , dependencies =
          [ Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "shinzui/pgmq-hs"
          , Schema.Dependency.ByName "hasql/hasql"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        , apiSource = None Schema.ApiSource
        }
      , { name = "shibuya-example"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "shibuya-example"
        , description = Some
            "Example demonstrating multi-processor setup with mock adapter"
        , lifecycle = None Schema.Lifecycle
        , visibility = Schema.Visibility.Internal
        , runtime = { deployable = True, exposesApi = False }
        , runtimeEnvironment = None Schema.RuntimeEnvironment
        , dependencies = emptyDeps
        , docs = emptyDocs
        , config = emptyConfig
        , apiSource = None Schema.ApiSource
        }
      , { name = "shibuya-pgmq-example"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "shibuya-pgmq-example"
        , description = Some
            "Real-world example with PGMQ, OpenTelemetry tracing, and Prometheus metrics"
        , lifecycle = None Schema.Lifecycle
        , visibility = Schema.Visibility.Internal
        , runtime = { deployable = True, exposesApi = True }
        , runtimeEnvironment = None Schema.RuntimeEnvironment
        , dependencies = emptyDeps
        , docs = emptyDocs
        , config = emptyConfig
        , apiSource = None Schema.ApiSource
        }
      , { name = "shibuya-core-bench"
        , type = Schema.PackageType.Other "Benchmark"
        , language = Schema.Language.Haskell
        , path = Some "shibuya-core-bench"
        , description = Some
            "Benchmarks for framework overhead vs pure streamly"
        , lifecycle = None Schema.Lifecycle
        , visibility = Schema.Visibility.Internal
        , runtime = emptyRuntime
        , runtimeEnvironment = None Schema.RuntimeEnvironment
        , dependencies = emptyDeps
        , docs = emptyDocs
        , config = emptyConfig
        , apiSource = None Schema.ApiSource
        }
      , { name = "shibuya-pgmq-adapter-bench"
        , type = Schema.PackageType.Other "Benchmark"
        , language = Schema.Language.Haskell
        , path = Some "shibuya-pgmq-adapter-bench"
        , description = Some
            "Throughput and concurrency benchmarks for the PGMQ adapter"
        , lifecycle = None Schema.Lifecycle
        , visibility = Schema.Visibility.Internal
        , runtime = emptyRuntime
        , runtimeEnvironment = None Schema.RuntimeEnvironment
        , dependencies = emptyDeps
        , docs = emptyDocs
        , config = emptyConfig
        , apiSource = None Schema.ApiSource
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
      , "composewell/streamly"
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
    , skills = [] : List Schema.Skill
    , subagents = [] : List Schema.Subagent
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
