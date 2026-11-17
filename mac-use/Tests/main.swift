import Foundation

Env.assertIsolated()

if CommandLine.arguments.dropFirst().first == "--child" {
    runChild(Array(CommandLine.arguments.dropFirst(2)))
}

registerCoreTests()
registerSafetyTests()
registerSnapshotTests()
registerInputTests()
registerToolsTests()
registerMCPTests()
registerStandardTests()
registerCLITests()
registerRegressionTests()

exit(Harness.exitCode)
