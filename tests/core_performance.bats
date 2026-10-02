#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_project_root

    TEST_DATA_DIR="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-perf.XXXXXX")"
    export TEST_DATA_DIR
}

teardown_file() {
    rm -rf "$TEST_DATA_DIR"
}

setup() {
    source "$PROJECT_ROOT/lib/core/base.sh"
}

@test "Perl timeout backend backs off short polls and preserves command status" {
    [[ -x /usr/bin/perl ]] || skip "Perl fallback unavailable"
    run /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
export MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN="" MO_TIMEOUT_PERL_BIN=/usr/bin/perl
source "$PROJECT_ROOT/lib/core/timeout.sh"
probe_dir=$(mktemp -d "$TEST_DATA_DIR/poll.XXXXXX")
# SAFE: exact mktemp-created test fixture, removed after the bounded probe exits.
trap 'rm -rf "$probe_dir"' EXIT
cat > "$probe_dir/MolePollProbe.pm" <<'PERL'
package MolePollProbe;
use strict;
use warnings;
use Time::HiRes ();
my $real_sleep = \&Time::HiRes::sleep;
my $polls = 0;
{
    no warnings 'redefine';
    *Time::HiRes::sleep = sub (;@) {
        open my $log, '>>', "$ENV{MOLE_POLL_FIXTURE}/intervals" or die $!;
        print {$log} "$_[0]\n";
        close $log or die $!;
        # The child cannot exit before six polls, even on a busy runner.
        if (++$polls == 6) {
            open my $release, '>', "$ENV{MOLE_POLL_FIXTURE}/release" or die $!;
            close $release or die $!;
        }
        return $real_sleep->(@_);
    };
}
1;
PERL
export PERL5LIB="$probe_dir" PERL5OPT=-MMolePollProbe MOLE_POLL_FIXTURE="$probe_dir"
rc=0
# Both helper and child have a deadline, so a broken handshake cannot hang.
run_with_timeout 10 /bin/bash --noprofile --norc -c '
    deadline=$((SECONDS + 10))
    while [[ ! -f "$MOLE_POLL_FIXTURE/release" ]]; do
        [[ $SECONDS -lt $deadline ]] || exit 99
        sleep 0.01
    done
    exit 7
' < /dev/null || rc=$?
printf 'RC=%s POLLS=%s\n' "$rc" "$(tr '\n' ',' < "$probe_dir/intervals")"
[[ $rc -eq 7 ]] || exit 1
awk '
    BEGIN { split("0.01 0.02 0.04 0.08 0.1 0.1", expected) }
    NR <= 6 && $1 != expected[NR] { bad = 1 }
    $1 <= 0 || $1 > 0.1 { bad = 1 }
    END { exit (bad || NR < 6) }
' "$probe_dir/intervals"
EOF
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [[ "$output" == *"RC=7 POLLS=0.01,0.02,0.04,0.08,0.1,0.1,"* ]]
}

@test "scan workers reap a completed peer before a blocked queue head" {
    run /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
release="$TEST_DATA_DIR/release-$$"
(while [[ ! -f "$release" ]]; do sleep 0.02; done) &
slow=$!
trap 'touch "$release"; wait "$slow" 2>/dev/null || true' EXIT
(exit 7) &
fast=$!
finished=""
rc=0
mole_wait_for_any_worker finished "$slow" "$fast" || rc=$?
[[ "$finished" == "$fast" && "$rc" == 7 ]] || exit 1
kill -0 "$slow" || exit 1
touch "$release"
wait "$slow"
printf 'fast-reaped slow-still-running\n'
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"fast-reaped slow-still-running"* ]] || return 1
}

@test "scan worker polling propagates interrupted sleep" {
    run /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
sleep 10 &
worker=$!
trap 'kill "$worker" 2>/dev/null || true; wait "$worker" 2>/dev/null || true' EXIT
sleep() { return 130; }
finished=""
rc=0
mole_wait_for_any_worker finished "$worker" || rc=$?
[[ "$rc" == 130 && -z "$finished" ]] || exit 1
printf 'interruption-propagated\n'
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"interruption-propagated"* ]] || return 1
}

@test "bytes_to_human handles large values efficiently" {
    # Measured in a plain child shell, not in this Bats process: Bats installs a
    # DEBUG trap that inflates 1000 calls to 1-2.5s, which hid a real regression.
    # ~40ms here; the 300ms budget still catches one added fork per call.
    local limit_ms="${MOLE_PERF_BYTES_TO_HUMAN_LIMIT_MS:-300}"
    local elapsed

    elapsed=$(
        /bin/bash --noprofile --norc -c '
            source "$1/lib/core/base.sh"
            bytes_to_human 1073741824 > /dev/null
            start=$(date +%s%N)
            for i in {1..1000}; do
                bytes_to_human 1073741824 > /dev/null
            done
            end=$(date +%s%N)
            printf "%s\n" $(( (end - start) / 1000000 ))
        ' _ "$PROJECT_ROOT"
    )

    [ "$elapsed" -lt "$limit_ms" ] || return 1
}

@test "bytes_to_human produces correct output for GB range" {
    result=$(bytes_to_human 1000000000)
    [ "$result" = "1.00GB" ]

    result=$(bytes_to_human 5000000000)
    [ "$result" = "5.00GB" ]
}

@test "bytes_to_human produces correct output for MB range" {
    result=$(bytes_to_human 1000000)
    [ "$result" = "1.0MB" ]

    result=$(bytes_to_human 100000000)
    [ "$result" = "100.0MB" ]
}

@test "bytes_to_human produces correct output for KB range" {
    result=$(bytes_to_human 1000)
    [ "$result" = "1KB" ]

    result=$(bytes_to_human 10000)
    [ "$result" = "10KB" ]
}

@test "bytes_to_human handles edge cases" {
    result=$(bytes_to_human 0)
    [ "$result" = "0B" ]

    run bytes_to_human "invalid"
    [ "$status" -eq 1 ]
    [ "$output" = "0B" ]

    run bytes_to_human "-100"
    [ "$status" -eq 1 ]
    [ "$output" = "0B" ]
}

@test "get_file_size returns the byte size and 0 for a missing file" {
    # A timing ratio against bare stat flaked on busy CI runners (#1816,
    # #1820) without ever catching a regression, so only the value is checked.
    local test_file="$TEST_DATA_DIR/size_test.txt"
    dd if=/dev/zero of="$test_file" bs=1024 count=100 2> /dev/null

    [ "$(get_file_size "$test_file")" = "102400" ] || return 1
    [ "$(get_file_size "$TEST_DATA_DIR/missing")" = "0" ]
}

@test "get_file_mtime returns valid timestamp" {
    local test_file="$TEST_DATA_DIR/mtime_test.txt"
    touch "$test_file"

    result=$(get_file_mtime "$test_file")

    [[ "$result" =~ ^[0-9]{10,}$ ]]
}

@test "get_file_owner returns current user for owned files" {
    local test_file="$TEST_DATA_DIR/owner_test.txt"
    touch "$test_file"

    result=$(get_file_owner "$test_file")
    current_user=$(whoami)

    [ "$result" = "$current_user" ]
}

@test "create_temp_file and cleanup_temp_files work efficiently" {
    local start end elapsed
    local limit_ms="${MOLE_PERF_CREATE_TEMP_FILE_LIMIT_MS:-3000}"

    declare -a MOLE_TEMP_DIRS=()

    start=$(date +%s%N)
    for i in {1..50}; do
        create_temp_file > /dev/null
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))

    [ "$elapsed" -lt "$limit_ms" ]

    [ "${#MOLE_TEMP_FILES[@]}" -eq 50 ]

    start=$(date +%s%N)
    cleanup_temp_files
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))
    [ "$elapsed" -lt "$limit_ms" ]

    [ "${#MOLE_TEMP_FILES[@]}" -eq 0 ]
}

@test "mktemp_file creates files with correct prefix" {
    local temp_file
    temp_file=$(mktemp_file "test_prefix")

    [[ "$temp_file" =~ test_prefix ]] || return 1

    [ -f "$temp_file" ]

    rm -f "$temp_file"
}

@test "get_optimal_parallel_jobs returns sensible values" {
    local result

    result=$(get_optimal_parallel_jobs)
    [[ "$result" =~ ^[0-9]+$ ]] || return 1
    [ "$result" -gt 0 ]
    [ "$result" -le 128 ]

    local scan_jobs
    scan_jobs=$(get_optimal_parallel_jobs "scan")
    [ "$scan_jobs" -gt "$result" ]

    local compute_jobs
    compute_jobs=$(get_optimal_parallel_jobs "compute")
    [ "$compute_jobs" -le "$scan_jobs" ]
}

@test "section tracking has minimal overhead" {
    local start end elapsed

    if ! declare -f note_activity > /dev/null 2>&1; then
        TRACK_SECTION=0
        SECTION_ACTIVITY=0
        note_activity() {
            if [[ $TRACK_SECTION -eq 1 ]]; then
                SECTION_ACTIVITY=1
            fi
        }
    fi

    note_activity

    start=$(date +%s%N)
    for i in {1..1000}; do
        note_activity
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))

    local limit_ms="${MOLE_PERF_SECTION_LIMIT_MS:-2000}"
    [ "$elapsed" -lt "$limit_ms" ]
}

@test "should_protect_path stays fast for many files under one container" {
    # A large app cache (4,514 Folo Cache_Data entries on one Mac) is checked
    # file by file; the per-call cost decides how long `mo clean` sits silent.
    # Timed in a child bash: Bats' DEBUG trap would dominate an in-process loop.
    local limit_ms="${MOLE_PERF_PROTECT_PATH_LIMIT_MS:-3000}"
    run /bin/bash -c '
        source "$1/lib/core/base.sh"
        source "$1/lib/core/app_protection.sh"
        base="$HOME/Library/Containers/is.follow/Data/Library/Application Support/Folo/Cache/Cache_Data/f_"
        should_protect_path "${base}warmup" || true
        start=$(date +%s%N)
        for i in {1..300}; do should_protect_path "${base}${i}" || true; done
        end=$(date +%s%N)
        echo $(((end - start) / 1000000))
    ' _ "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    echo "elapsed=${output}ms limit=${limit_ms}ms"
    [ "$output" -lt "$limit_ms" ]
}
