let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/ad9960dd3dd3b33eadd45f17bcf430b0e1ec13bc/package.dhall
        sha256:83aa1432e98db5da81afde4ab2057dcab7ce4b2e883d0bc7f16c7d25b917dd0c

let emptyRuntime = { deployable = False, exposesApi = False }

let emptyDeps = [] : List Schema.Dependency

let emptyDocs = [] : List Schema.DocRef.Type

let emptyConfig = [] : List Schema.ConfigItem.Type

in  Schema.Project::{ project =
      Schema.ProjectIdentity::{ name = "shibuya"
      , namespace = "shinzui"
      , type = Schema.PackageType.Library
      , description = Some
          "Supervised queue processing framework for Haskell, inspired by Broadway (Elixir)"
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Active
      , domains = [ "concurrency", "queue-processing" ]
      , owners = [ "shinzui" ]
      }
    , repos =
      [ Schema.Repo::{ name = "shibuya"
        , github = Some "shinzui/shibuya"
        , localPath = Some "."
        }
      ]
    , packages =
      [ Schema.Package::{ name = "shibuya-core"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shibuya-core"
        , description = Some
            "Core framework: supervision, backpressure, ack semantics, and tracing"
        , runtime = emptyRuntime
        , dependencies =
          [ Schema.Dependency.ByName "effectful/effectful"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        }
      , Schema.Package::{ name = "shibuya-metrics"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shibuya-metrics"
        , description = Some
            "HTTP/JSON, Prometheus, and WebSocket metrics endpoints"
        , runtime = { deployable = False, exposesApi = True }
        , dependencies =
          [ Schema.Dependency.ByName "effectful/effectful"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        }
      , Schema.Package::{ name = "shibuya-pgmq-adapter"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shibuya-pgmq-adapter"
        , description = Some
            "PGMQ adapter with visibility timeout leasing, retry handling, and DLQ support"
        , runtime = emptyRuntime
        , dependencies =
          [ Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "shinzui/pgmq-hs"
          , Schema.Dependency.ByName "hasql/hasql"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        }
      , Schema.Package::{ name = "shibuya-example"
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
      , Schema.Package::{ name = "shibuya-pgmq-example"
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
      , Schema.Package::{ name = "shibuya-core-bench"
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
      , Schema.Package::{ name = "shibuya-pgmq-adapter-bench"
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
      [ Schema.PackageBundle::{ name = "shibuya-full"
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
    , agents =
      [ Schema.AgentHint::{ role = "framework-dev"
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
      , Schema.AgentHint::{ role = "adapter-dev"
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
    , docs =
      [ Schema.DocRef::{ key = "architecture"
        , kind = Schema.DocKind.Reference
        , audience = Schema.DocAudience.Internal
        , description = Some
            "Architecture docs: message flow, core types, metrics"
        , location = Schema.DocLocation.LocalDir "docs/architecture"
        }
      , Schema.DocRef::{ key = "readme"
        , kind = Schema.DocKind.Guide
        , audience = Schema.DocAudience.User
        , description = Some "Project README with quickstart"
        , location = Schema.DocLocation.LocalFile "README.md"
        }
      , Schema.DocRef::{ key = "changelog"
        , kind = Schema.DocKind.Notes
        , audience = Schema.DocAudience.User
        , description = Some "Release changelog"
        , location = Schema.DocLocation.LocalFile "CHANGELOG.md"
        }
      , Schema.DocRef::{ key = "hackage"
        , kind = Schema.DocKind.Reference
        , audience = Schema.DocAudience.API
        , description = Some "Hackage package page"
        , location =
            Schema.DocLocation.Url
              "https://hackage.haskell.org/package/shibuya-core"
        }
      ]
    }
