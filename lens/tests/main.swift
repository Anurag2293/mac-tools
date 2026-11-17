import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

await detectorTests()
await hotkeyTests()
await textTests()
await colorTests()
await blockTests()
await googleTests()
await translatorTests()
await visionTests()

printSummary()
exit(failedTests == 0 ? 0 : 1)
