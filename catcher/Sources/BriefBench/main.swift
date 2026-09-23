import Brief
import Foundation

let code = await BriefBench.cli(Array(CommandLine.arguments.dropFirst()))
exit(code)
