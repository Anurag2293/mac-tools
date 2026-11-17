import Foundation

Env.assertIsolated()

registerCoreTests()
registerSafetyTests()
registerSnapshotTests()
registerInputTests()
registerToolsTests()
registerMCPTests()
registerStandardTests()
registerCLITests()

exit(Harness.exitCode)
