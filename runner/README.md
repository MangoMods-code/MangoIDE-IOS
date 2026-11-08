# MangoIDE runner

Runs code for MangoIDE in languages iOS can't run on the phone. It answers the same API as Piston
(`POST /api/v2/execute`, `GET /api/v2/runtimes`), so the app talks to it as a "runner server".

Every request needs the key in the `RUNNER_KEY` variable, sent as `Authorization: Bearer <key>`.
Code runs as an unprivileged user with a time limit, output limit and a fresh folder per run.

Deployed on Railway from this folder (root directory `/runner`).
