## Justfile - TermAssertClient.

alias t := test
alias fmt := format

src-paths := "--path:src --path:tests"
nim-flags := "--styleCheck:usages --styleCheck:error"

tests := "tests/test_client_smoke.nim"

build:
    @mkdir -p test-logs
    @for t in {{tests}}; do \
      echo "Building $t"; \
      nim c {{nim-flags}} {{src-paths}} --mm:orc -d:release --threads:on \
          -o:test-logs/$(basename $t .nim) $t 2>&1 | tee -a test-logs/build.log; \
    done

test: test-orc

test-orc:
    just _matrix orc release on

test-arc:
    just _matrix arc release on

test-refc:
    just _matrix refc release on

test-threads-off:
    just _matrix orc release off

test-all: test-orc test-arc test-refc test-threads-off

_matrix mm mode threads:
    @mkdir -p test-logs
    @for t in {{tests}}; do \
      echo "[{{mm}}/{{mode}}/threads:{{threads}}] $t"; \
      nim c {{nim-flags}} {{src-paths}} \
        --mm:{{mm}} -d:{{mode}} --threads:{{threads}} \
        -r $t 2>&1 | tee -a test-logs/{{mm}}-{{mode}}-threads-{{threads}}.log; \
    done

lint: lint-nim lint-nix

lint-nim:
    @mkdir -p test-logs
    nim check {{nim-flags}} {{src-paths}} --mm:orc src/term_assert_client.nim 2>&1 | tee test-logs/lint-nim.log
    @for t in {{tests}}; do \
      echo "Checking $t"; \
      nim check {{nim-flags}} {{src-paths}} --mm:orc --threads:on $t 2>&1 | tee -a test-logs/lint-nim.log; \
    done

lint-nix:
    nixfmt --check flake.nix

format: format-nim format-nix

format-nim:
    @if command -v nimpretty >/dev/null 2>&1; then \
      nimpretty src/term_assert_client.nim tests/*.nim; \
    else \
      echo "nimpretty not available; skipping Nim formatting"; \
    fi

format-nix:
    nixfmt flake.nix

bump-version version:
    sed -i 's/^version[[:space:]]*=.*/version       = "{{version}}"/' term_assert_client.nimble

bench:
    @echo "TermAssertClient has no benchmark suite — it's a tiny IPC stub."

bench-quick:
    just bench

clean:
    rm -rf test-logs nim-cache
    find tests -maxdepth 1 -type f -executable -name "test_*" -not -name "*.nim" -delete
