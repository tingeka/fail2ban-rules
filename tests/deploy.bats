#!/usr/bin/env bats

# shellcheck disable=SC1091
# shellcheck disable=SC2034

setup() {
    export SANDBOX="./tests/sandbox"
    rm -rf "$SANDBOX"
    mkdir -p "$SANDBOX/deploy"
    export TEST_SANDBOX="$SANDBOX/deploy"

    # Target directories (sandboxed)
    export FAIL2BAN_ACTION_DIR="$TEST_SANDBOX/action.d"
    export FAIL2BAN_FILTER_DIR="$TEST_SANDBOX/filter.d"
    export FAIL2BAN_JAIL_DIR="$TEST_SANDBOX/jail.d"
    export TMP_DIR="$TEST_SANDBOX/tmp_repo"
    mkdir -p "$FAIL2BAN_ACTION_DIR" "$FAIL2BAN_FILTER_DIR" "$FAIL2BAN_JAIL_DIR"

    export REPO_URL="https://github.com/tingeka/fail2ban-rules.git"

    # Source deploy script FIRST
    source ./deploy.sh

    # THEN override the variables (this is key!)
    export FORCE=true
    export DRY_RUN=false
    export DEBUG=false

    # Override cleanup_tmp to not delete in tests
    # shellcheck disable=SC2329
    cleanup_tmp() {
        echo "Skipping cleanup in tests"
    }
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "full deployment clones repo and copies files" {
    run main --force
    [ "$status" -eq 0 ]

    # Repo cloned
    [ -d "$TMP_DIR/.git" ]

    # Check all files in action.d that exist in the repo
    if [ -d "$TMP_DIR/action.d" ]; then
        for f in "$TMP_DIR"/action.d/*.conf; do
            [[ -f "$f" ]] || continue
            [ -f "$FAIL2BAN_ACTION_DIR/$(basename "$f")" ] || fail "Missing action file: $(basename "$f")"
        done
    fi

    # Check all files in filter.d that exist in the repo
    if [ -d "$TMP_DIR/filter.d" ]; then
        for f in "$TMP_DIR"/filter.d/*.conf; do
            [[ -f "$f" ]] || continue
            [ -f "$FAIL2BAN_FILTER_DIR/$(basename "$f")" ] || fail "Missing filter file: $(basename "$f")"
        done
    fi

    # Check all files in jail.d that exist in the repo
    if [ -d "$TMP_DIR/jail.d" ]; then
        for f in "$TMP_DIR"/jail.d/*.conf; do
            [[ -f "$f" ]] || continue
            [ -f "$FAIL2BAN_JAIL_DIR/$(basename "$f")" ] || fail "Missing jail file: $(basename "$f")"
        done
    fi

    # Deployment finished
    [[ "$output" == *"Deployment finished."* ]]
}

@test "dry-run mode does not modify target dirs" {
    run main --dry-run --force
    [ "$status" -eq 0 ]

    # Output contains DRY-RUN markers
    [[ "$output" == *"[DRY-RUN]"* ]]

    # Target directories should be empty (only contain what we created in setup)
    [ -z "$(find "$FAIL2BAN_ACTION_DIR" -name "*.conf" 2>/dev/null)" ]
    [ -z "$(find "$FAIL2BAN_FILTER_DIR" -name "*.conf" 2>/dev/null)" ]
    [ -z "$(find "$FAIL2BAN_JAIL_DIR" -name "*.conf" 2>/dev/null)" ]
}

@test "unknown argument fails" {
    run main --unknown
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "help message prints usage" {
    # Test the usage function directly instead of main --help which calls exit
    run usage
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "parse_args handles help flag" {
    # Test that parse_args with --help returns 0 (which triggers exit in main)
    run bash -c 'source ./deploy.sh; parse_args --help >/dev/null 2>&1; echo $?'
    [[ "$output" == "0" ]]
}