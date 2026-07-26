# Sonar retry policy exceeds its workflow timeout

## I have done the following

- [x] I searched the existing issues.
- [x] I reproduced the issue using the `main` branch.

## Steps to reproduce

1. Run exact-main CI while SonarCloud takes longer than 300 seconds to process
   an uploaded analysis.
2. Observe `make sonar-scan` start its configured second of three attempts
   after the first quality-gate wait expires.
3. Observe GitHub Actions terminate the SonarQube step at its independent
   ten-minute timeout before the retry policy can finish.

Exact source [`eabc04736d83bf62c06781ee4b0cf2d612c40af2`](https://github.com/stephenlclarke/container-compose/commit/eabc04736d83bf62c06781ee4b0cf2d612c40af2) reproduced the mismatch twice in [CI run 30204614991](https://github.com/stephenlclarke/container-compose/actions/runs/30204614991). Both attempts uploaded the exact revision successfully. The retry passed all 1,224 Swift tests in 41 suites with 92.66% Swift line coverage and 89.88% Go statement coverage before SonarCloud's processing wait timed out.

## Problem description

The scanner target permits three attempts. Each attempt can spend 300 seconds waiting for the quality gate, in addition to scanner analysis and upload time, and the target waits 20 seconds between attempts. The workflow instead allows only ten minutes for the complete target. That outer deadline cannot represent the retry policy it invokes, so a reachable but delayed SonarCloud service can kill a valid later attempt and block exact-main prerelease publication for the wrong reason.

The workflow step needs a 25-minute budget that covers the three waits, scanner work, and both retry delays. The existing API-aware enforcement step must remain unchanged: if SonarCloud is reachable and every scanner attempt fails, CI must still fail closed.

## Environment

- **OS**: macOS 26 GitHub-hosted runner
- **Container**:
  `221fafc24ebd19502f4553e0b5d38c14be3f2b22`
- **Containerization**:
  `164088e02e16ed80e536d0c59822b09931d213df`
- **container-compose**:
  `eabc04736d83bf62c06781ee4b0cf2d612c40af2`

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
- [x] I removed secrets and private data from this report.
