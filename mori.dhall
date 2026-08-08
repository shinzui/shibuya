let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/06da43590476f4ddc64386e91be9ca88a1f3c9d6/package.dhall
        sha256:dd0c3e0094714498fe7b2562aa85998624b13198758d9160b5ea74b253491836

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
      ]
    , bundles =
      [ Schema.PackageBundle::{ name = "shibuya-full"
        , description = Some
            "Complete Shibuya stack with metrics"
        , packages =
          [ "shibuya-core"
          , "shibuya-metrics"
          ]
        , primary = "shibuya-core"
        }
      ]
    , dependencies =
      [ "effectful/effectful"
      , "composewell/streamly"
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
    , okfBundles =
      [ Schema.OkfBundle::{ name = "capabilities"
        , path = "docs/capabilities"
        , profile = Some "docs/capabilities/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "What Shibuya provides today, one concept per capability, with stable CAP-N handles, compatibility promises, and evidence"
        }
      ]
    }
