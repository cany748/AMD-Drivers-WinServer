# Test fixtures

Every `.inf` file here is **synthetic and written by hand** for the unit tests. Each starts with
the line `; SYNTHETIC TEST FIXTURE`, and the tests check for it. They copy the *layout* of a display
INF (`[Manufacturer]` decorations, model sections, `DriverVer`, `CatalogFile`). They contain no AMD
content.

Never put files from an AMD driver package here. The repository must not contain AMD files.
