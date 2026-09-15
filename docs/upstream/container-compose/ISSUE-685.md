# Issue 685: clear remaining SonarQube maintainability findings

The current SonarQube gate passes and reports no bugs, vulnerabilities, or unreviewed security hotspots, but the `main` dashboard retains 40 maintainability findings and reports 86.7% overall coverage. The findings mix two genuine high-complexity Go functions with Swift protocol constants, immutable value-model initializers, required keyword-shaped wire fields, and intentionally empty lifecycle callbacks.

The maintained Go implementation must be simplified without changing volume-initialization validation, recovery, or publication behavior. Intentionally empty Swift callbacks must explain their lifecycle purpose, and the nested attachment-wait closure must become a named operation. Findings that exist only because fixed Docker Engine routes, guest paths, immutable wire records, or public protocol field names resemble configurable application code must receive narrow rule-and-resource dispositions; maintained operational code must remain analyzed.

Focused tests must cover the extracted Go boundaries with at least 90% line coverage for the changed functions. The authoritative SonarQube analysis must retain the exact lowercase commit SHA as `sonar.projectVersion`, use the project-level `Previous version` policy, pass the quality gate, and report zero unresolved issues and security hotspots in the pull-request new-code period. The honest overall coverage metric remains visible and is not raised by broad source or coverage exclusions.

Related issue: [#685](https://github.com/stephenlclarke/container-compose/issues/685).
