# Test Failure and Fix Log

Prepared: 2026-11-15
Scope: Confirmed test/build failures found while validating the current `main` checkout.

This log records verified failures and fixes. It is a running document; add entries when the combined feature suite discovers additional issues. Do not record a suspected issue as a confirmed defect until it has reproduction evidence.

## Confirmed findings

### TF-001 — Branch service tests did not compile: nested test declarations

- **Area:** Branch API, `services/branch-api/internal/branch/service_test.go`
- **Test type:** Go unit-test compilation
- **Symptom:** `go test ./...` reported `expected '(', found TestNormalizeTimeRejectsBoundaryFormats` at line 154.
- **Cause:** Several package-level test functions had been indented and placed inside `TestBranchTypeRevenueRules`. Go permits function literals inside functions but does not permit named `func Test...` declarations nested inside another function.
- **Fix:** Moved `TestNormalizeTimeRejectsBoundaryFormats`, `TestValidateLateRateAcceptsZeroAndTwoDecimals`, `TestValidateNameTrimsUnicodeAndCountsRunes`, and `TestUpdatePropagatesRepositoryErrors` to package scope. Kept the revenue assertions inside `TestBranchTypeRevenueRules`.
- **Why this fix:** Tests must be discoverable as package-level Go test functions. Restoring package scope preserves the intended coverage and allows the compiler and `go test` to discover each case.
- **Verification:** `go test ./...` from `services/branch-api` passes after the fix.

### TF-002 — Branch service tests did not compile: duplicate helper name

- **Area:** Branch API, `services/branch-api/internal/branch/service_test.go`
- **Test type:** Go unit-test compilation
- **Symptom:** After TF-001 was corrected, compilation reported `stringPointer redeclared in this block`; the helper was also defined in `service_qa_test.go`.
- **Cause:** Go files in the same package share one package-level namespace. A helper added in a second `_test.go` file reused a name already declared by another test file.
- **Fix:** Renamed the helper in `service_test.go` to `serviceStringPointer` and updated its call sites.
- **Why this fix:** The tests need a pointer helper, but its name must be unique across all source and test files in the package. A local descriptive name avoids changing the existing QA tests or their callers.
- **Verification:** `go test ./...` from `services/branch-api` passes after the rename.

## Why these failures mattered

Both findings were test-code defects, not evidence that the Branch API runtime behavior was broken. However, either compile error prevents **all** tests in the Branch API package from running. CI would fail at the same stage, and the service would have no trustworthy test result until the test package compiled. These failures also show why an integrated suite must compile every service and feature together before we treat it as ready to merge.

## Prevention steps

1. Keep every named `TestXxx(t *testing.T)` declaration at package scope. Close the current test function before starting another one; use editor brace matching and gofmt to catch misplaced blocks.
2. Before committing, run `gofmt` on changed Go files and `go test ./...` for the affected module. For integrated changes, run the repository-wide module test target after assembling the candidate feature set.
3. Use distinctive helper names or a shared test helper file. Before adding a package-level helper, search all `.go` and `_test.go` files in that package for an existing declaration.
4. Keep tests in the same package only when they need unexported symbols; remember that all files with the same package declaration share identifiers.
5. Configure CI to compile and test the complete integrated candidate, and retain the failing test output as an artifact. Do not merge to `main` until the combined test gate passes or an explicitly accepted blocker is documented.
6. When adding multiple tests in one edit, review the whole edited region, run gofmt, and inspect the diff before running or committing the change.

## Execution environment notes

- Go 1.27.2 was installed under `D:\DevTools\Go`; Go build and module caches were placed under `D:\DevTools\Go` for this session.
- Current `main` service tests previously passed for Auth and Attendance. Branch passed after the two fixes above.
- Docker Compose runtime validation remains unverified because the Docker Desktop Linux engine was unavailable in the environment at the time it was checked. This is an environment blocker, not a confirmed application defect.

### TF-006 — Compose role bootstrap did not create feature API roles

- **Test type:** Full Compose build/runtime smoke.
- **Symptom:** The unified migration failed with `role "central_kitchen_app" does not exist`.
- **Cause:** Compose used `/bin/sh -ec` as entrypoint while passing psql and its flags as separate arguments. The shell did not run the intended psql command.
- **Fix:** Set `psql` as the entrypoint and pass its variables and SQL file as explicit command arguments.
- **Retest:** Fresh-database migration validation passed in GitHub Actions after the fix. Full Compose smoke remains pending.

### TF-007 — Existing API health checks depended on missing wget

- **Test type:** Docker/runtime health check.
- **Symptom:** Auth became unhealthy during full Compose smoke.
- **Cause:** Compose health checks invoke `wget`, but Auth, Branch, and Attendance runtime images installed CA certificates only.
- **Fix:** Added `wget` to the runtime packages in all three Dockerfiles.
- **Retest:** Full Compose CI smoke passed for all nine APIs on commit `e8f23637d447a9a0a25839f3f0a82dd58f851e50` (run `43733645153`).

### TF-008 — Role bootstrap passed literal environment placeholders to psql

- **Test type:** Combined Docker Compose build and runtime smoke across all APIs.
- **Symptom:** The next combined run failed the new role-bootstrap invocation with exit code 127 before migration could start.
- **Cause:** Adding a mounted shell wrapper introduced another command-resolution boundary and still left credentials dependent on command/entrypoint behavior.
- **Fix:** Removed the wrapper. The shared psql bootstrap file now reads all nine passwords directly from its process environment using psql `\\getenv` commands, and it raises an error unless all expected roles exist. Both Compose and the fresh-database workflow use the same direct `psql -f roles.sql` path.
- **Why this fix:** psql itself handles environment-to-variable transfer, so no shell interpolation or argument forwarding is needed. The role postcondition makes silent bootstrap success impossible.
- **Retest:** Fresh-database role and migration validation passed, and the all-service Compose smoke passed on commit `e8f23637d447a9a0a25839f3f0a82dd58f851e50` (GitHub Actions run `43733645153`).
- **Prevention:** Keep database bootstrap behavior identical between CI and Compose, and validate the resulting role state inside the bootstrap transaction/path before allowing dependent migrations to run.

### TF-009 — Inventory API attempted DDL with its restricted runtime role

- **Test type:** Full Compose startup and database migration smoke.
- **Symptom:** Role creation and Goose migrations succeeded, but Inventory became unhealthy with `permission denied for schema public` while creating its embedded migration tracking table.
- **Cause:** Inventory re-ran DDL migrations during API startup using `inventory_app`. Runtime roles intentionally lack schema ownership and `CREATE` privileges, and the same inventory schema is already provisioned by the privileged shared migration runner.
- **Fix:** Removed the redundant embedded migration call from Inventory startup. Deployment's Goose service remains the single DDL migration owner and Compose starts Inventory only after that service succeeds.
- **Why this fix:** Schema changes run once under the dedicated migration account; API connections retain least privilege for their runtime queries.
- **Retest:** All nine API images built and the full Compose stack became healthy; all health endpoints passed on commit `e8f23637d447a9a0a25839f3f0a82dd58f851e50` (run `43733645153`).
- **Prevention:** Keep schema migration execution in the dedicated deploy migration stage; runtime services should only connect and serve requests under their restricted database roles.

### TF-003 — Integrated feature modules failed the combined Go suite

- **Environment/commit:** Integrated candidate branch; Windows amd64; Go 1.27.2; 2026-11-15.
- **Test type:** Combined unit tests (`go test ./...` in every `services/**/go.mod` module).
- **Initial failures:** Central Kitchen returned internal errors for missing goods and malformed supply request items; negative received/approved quantities were not rejected before repository/database calls. Standalone Inventory recorded an adjustment's resulting balance instead of its signed delta. Sales allowed discount cancellation on a closed shift; a valid cancellation fixture also omitted its expected open shift.
- **Fixes:** Added appropriate Central Kitchen 404/400 mappings and request item validation before DB access; preserved the signed inventory adjustment delta as movement quantity; required an active open shift before Sales discount cancellation; made the valid test fixture represent an open shift.
- **Follow-up:** The handler contract tests distinguished `validation_error` for a missing movement reason from `invalid_payload` for malformed requests. The mapping now preserves that distinction.
- **Retest:** Combined run passed across all nine Go modules. Output: `test-results/combined-go-test-run.txt`.

### TF-004 — Docker engine absent at first runtime check

- **Test type:** Docker engine / Compose build / runtime smoke.
- **Cause:** Docker Desktop was installed but not running; its Linux named-pipe endpoint did not exist.
- **Fix:** Started Docker Desktop. `docker info` then reported server 29.8.0, Linux.
- **Retest:** Compose image builds succeeded for Auth, Branch, Attendance, Menu, and the Goose migration runner. On an isolated smoke database, Goose migrations completed and all four API containers reported healthy; `/health` returned 200 on ports 9001, 9002, 9003, and 9005.
- **Additional issue and handling:** Menu's Dockerfile used Go 1.23 despite its module requiring 1.27.2; updated the builder/runtime stages and rebuilt successfully. An initial smoke environment also had an occupied host port and mismatched development seed settings; used a separate smoke volume/port and production mode for the disposable health-only Auth check. Existing local database data was retained.
- **Scope limitation:** Current Compose still does not include Inventory, Transfer, Sales, Cost, or Central Kitchen services. Their integration into deployment and feature-level DB flows remain open.

### TF-010 — Final integrated candidate verification

- **Environment/commit:** GitHub Actions `ubuntu-latest`; PR #24 head `e8f23637d447a9a0a25839f3f0a82dd58f851e50`; 2026-11-15.
- **Test types:** Combined Go unit/build suite, feature service tests, OpenAPI lint, fresh-database migration/schema/role validation, service-specific CI validation, Docker image build, Compose runtime startup, and HTTP health smoke.
- **Result:** PASS. All nine API services built and became healthy after role bootstrap and shared migrations. Health endpoints passed for ports 9001–9008 and 9010. Combined Go tests, feature service tests, migration checks, OpenAPI lint, and existing API validations passed.
- **Evidence:** [Full Compose Actions run](https://github.com/NorthstarEngineering/RAS-Backend/actions/runs/43733645153); [PR #24](https://github.com/NorthstarEngineering/RAS-Backend/pull/24).
- **Remaining coverage boundary:** This verifies deployment startup, DB migrations/roles, and API liveness. It does not execute authenticated business transactions through every feature API or validate an external mobile app repository. Those remain separate integration coverage items.

### TF-011 — Terraform plan initially read the wrong state object

- **Affected area:** AWS development Terraform backend configuration; `infra/terraform/dev`.
- **Test type:** Infrastructure plan/state validation.
- **Symptom:** A read-only plan proposed recreating the VPC, RDS database, EC2 host, and API Gateway resources.
- **Expected vs. actual:** The plan should reconcile against the existing versioned S3 state. The backend had been initialized without its non-default object key, so Terraform read an empty root key instead.
- **Cause:** The state object is `ras-backend/dev/terraform.tfstate`, not the default `terraform.tfstate`.
- **Fix:** Reinitialized with the bucket, region, profile, and explicit `key=ras-backend/dev/terraform.tfstate`. The live state has six resource blocks; current AWS inventory has no RDS instance or application EC2 host. The corrected plan proposes 57 additions, one in-place security-group change, and zero deletions to recreate the documented development stack and add the feature repositories/routes.
- **Impact/severity/status:** High deployment risk if applied against an empty state; resolved as a state-selection error. The plan was not applied.
- **Retest:** Correct backend state loaded and plan completed. `terraform validate` passed. The full cloud rollout remains pending.
- **Follow-up fix:** The lifecycle helper also omitted the non-default key, despite the documentation. Added the explicit `key=ras-backend/dev/terraform.tfstate` backend config to `scripts/aws-dev.ps1` so future lifecycle plans select the same verified object.
- **Prevention:** Use `scripts/aws-dev.ps1` or always initialize with the documented bucket **and key**. Review the Terraform state list and plan summary before applying; stop if an existing database or host is unexpectedly planned for creation.

### TF-012 — AWS deployment path omitted the six feature APIs

- **Affected area:** API Gateway proxy, EC2 deployment helper, Terraform ECR/network configuration, runtime secrets, and `scripts/aws-dev.ps1`.
- **Test type:** Deployment configuration and API contract review.
- **Symptom:** Before this fix, the cloud proxy routed only Auth, Branch, and Attendance; the EC2 deploy helper and ECR IAM policy also supported only those three services. Feature requests therefore had no cloud route or deployment target.
- **Expected vs. actual:** All nine services should have isolated gateway route namespaces, verified identity headers, ECR images, runtime DB credentials, and startup checks. The AWS path contained only three application mappings.
- **Fix:** Added route rewrites for Menu, Central Kitchen, Inventory, Cost, Sales, and Transfer; forward verified JWT `sub`/role/branch claims as identity headers; add six ECR repositories and scoped host/network access; add required runtime credentials to the ignored local Terraform secret file; build, deploy, and health-check all nine services; and make Menu's PostgreSQL TLS mode configurable for RDS.
- **Impact/severity/status:** Feature services were unavailable through the AWS development API. Configuration changes are implemented locally and are being validated; cloud apply remains pending.
- **Evidence:** Proxy test cases cover all nine service mappings and identity forwarding. Combined Go tests passed across all nine modules; Terraform validation passed. Cloud plan: 57 additions, one in-place change, zero deletions.
- **Prevention:** Keep the API route map, ECR repository list, runtime secret schema, host deployment map, and Compose service list aligned whenever a feature API is added.

### TF-014 — Menu cloud proxy removed a required route segment

- **Affected area:** AWS API Gateway request proxy mapping for the Menu API.
- **Test type:** Proxy routing test compared against the actual Go handler registration.
- **Symptom:** `/api/v1/menu/...` was rewritten as `/api/v1/...`, while the Menu API registers its routes under `/api/v1/menu`.
- **Cause:** The proxy test expected the prefix to be removed without checking the service router. Its expected path repeated the same incorrect assumption as the implementation.
- **Fix:** Keep `/api/v1/menu` intact when forwarding to port 9005 and update the test to expect `/api/v1/menu/...`.
- **Impact/severity/status:** Menu feature requests would have reached the wrong downstream route and returned 404. Fixed before PR submission.
- **Retest:** `node --test infra/terraform/dev/request-proxy.test.mjs` passes all route cases.
- **Prevention:** Compare each proxy mapping to the concrete router group in the target API as well as its public/mobile route.

### TF-013 — Local combined Docker build exhausted the C: volume

- **Affected area:** Local Docker Desktop runtime and the all-service Compose smoke test.
- **Test type:** Combined container build, database migration, and nine-service health smoke.
- **Symptom:** Docker Desktop initially could not start; after moving only rotated Docker diagnostic logs and stale installer/provider temp files to D:, the daemon started. The combined build then terminated with a Docker Desktop RPC EOF while building the Inventory API, and C: again reached zero free bytes.
- **Cause:** Docker's existing WSL virtual disk is approximately 22 GiB and stored on C:. The host has insufficient free space for the layer expansion from this multi-image build. The workflow's existing Compose smoke on GitHub Actions passed previously, but the current local attempt did not finish.
- **Attempted recovery:** Preserved the diagnostic logs, crash dump, installer, and provider files under `D:\DevTools\Go\recovered-c-disk`. The data disk remained in use by Windows virtualization, so relocation could not be completed safely. Existing Docker images, containers, and volumes were not pruned or deleted.
- **Status/impact:** Local all-service Compose result is incomplete; do not report the local run as passed. Keep this cloud deployment unverified until the Docker disk is moved to D: through Docker Desktop's storage settings, the daemon is healthy, and the combined smoke passes. GitHub Actions remains the independent Linux container-smoke gate.
- **Prevention:** Keep Go, Terraform, and Docker build storage on D: where possible, reserve adequate host free space before building all services together, and retain a D:-based Docker disk so large image builds cannot exhaust the Windows system volume.


