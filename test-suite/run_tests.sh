#!/bin/bash

: ${TIMEOUT:=150}

generate_xml()
{
    local xml_path=$1
    local testnames=$2

    echo -e "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
    <testsuites>
        <testsuite name=\"Tests\" tests=\"$(($test_pass + $test_fail))\" failures=\"$test_fail\" errors=\"0\" time=\"\">
${testnames}        </testsuite>
    </testsuites>" > "${xml_path}/test-results.xml"
}

ALL_TEST_NAMES=(
    "CLITestBreakpoint"
    "MIExampleTest"
    "MITestBreakpoint"
    "MITestExpression"
    "MITestVariables"
    "MITestStepping"
    "MITestEvaluate"
    "MITestException"
    "MITestEnv"
    "MITestGDB"
    "MITestExecAbort"
    "MITestExecInt"
    "MITestHandshake"
    "MITestTarget"
    "MITestExceptionBreakpoint"
    "MITestExtensionMethods"
    "MITestExitCode"
    "MITestEvalNotEnglish"
    "MITest中文目录"
    "MITestSrcBreakpointResolve"
    "MITestEnum"
    "MITestAsyncStepping"
    "MITestBreak"
    "MITestBreakpointToModule"
    "MITestNoJMCNoFilterStepping"
    "MITestNoJMCBreakpoint"
    "MITestNoJMCAsyncStepping"
    "MITestNoJMCExceptionBreakpoint"
    "MITestSizeof"
    "MITestAsyncLambdaEvaluate"
    "MITestGeneric"
    "MITestEvalArraysIndexers"
    "MITestBreakpointWithoutStop"
    "MITestBreakpointUpdate"
    "VSCodeExampleTest"
    "VSCodeTestBreakpoint"
    "VSCodeTestFuncBreak"
    "VSCodeTestAttach"
    "VSCodeTestPause"
    "VSCodeTestDisconnect"
    "VSCodeTestThreads"
    "VSCodeTestVariables"
    "VSCodeTestEvaluate"
    "VSCodeTestStepping"
    "VSCodeTestEnv"
    "VSCodeTestExitCode"
    "VSCodeTestEvalNotEnglish"
    "VSCodeTest中文目录"
    "VSCodeTestSrcBreakpointResolve"
    "VSCodeTestEnum"
    "VSCodeTestAsyncStepping"
    "VSCodeTestBreak"
    "VSCodeTestNoJMCNoFilterStepping"
    "VSCodeTestNoJMCBreakpoint"
    "VSCodeTestNoJMCAsyncStepping"
    "VSCodeTestExceptionBreakpoint"
    "VSCodeTestNoJMCExceptionBreakpoint"
    "VSCodeTestSizeof"
    "VSCodeTestAsyncLambdaEvaluate"
    "VSCodeTestGeneric"
    "VSCodeTestEvalArraysIndexers"
    "VSCodeTestExtensionMethods"
    "VSCodeTestBreakpointWithoutStop"
)

# Skipped tests:
# VSCodeTest297killNCD --- is not automated enough. For manual run only.
for i in "$@"
do
case $i in
    -x=*|--xml=*)
    XML_ABS_PATH="${i#*=}"
    generate_report=true
    shift
    ;;
    -c|--coverage)
    code_coverage_report=true
    shift
    ;;
    *)
        TEST_NAMES="$TEST_NAMES *"
    ;;
esac
done

TEST_NAMES="$@"

if [[ -z $NETCOREDBG ]]; then
    NETCOREDBG="../bin/netcoredbg"
fi

if [[ -z $OBJS_DIR ]]; then
    OBJS_DIR="../build/src/CMakeFiles/netcoredbg.dir/"
fi

if [[ -z $TEST_NAMES ]]; then
    TEST_NAMES="${ALL_TEST_NAMES[@]}"
    # delete all accumulated coverage data
    find $OBJS_DIR -name '*.gcda' -delete
fi

dotnet build TestRunner || exit $?

test_pass=0
test_fail=0
test_list=""
test_xml=""

DOC=<<EOD
  test_timeout run a command with timelimit and with housekeeping of all child processes
  Usage: test_timeout <timeout> <command>

  Handles:
  * ^C (SIGINT)
  * SIGTERM and some another cases to terminate script
  * timeout
  * command termination with error code
  * deep tree of command's processes
  * broken-in-midle tree of command's processes (orphan subchildren)
  * set -e agnostic
EOD
test_timeout()(
    set +o | grep errexit | grep -qw -- -o && saved_errexit="set -e"

    kill_hard(){
        kill -TERM $1
        sleep 0.5
        kill -KILL $1
    } 2>/dev/null

    set -m
    (
        {
            sleep $1
            echo "task killed by timeout" >&2
            get_pgid() { set -- $(cat /proc/self/stat); echo $5; }
            kill -ALRM -$(get_pgid) >/dev/null 2>&1
        } &
        shift
        $saved_errexit
        "$@"
    ) &
    pgid=$!
      trap "kill -INT -$pgid; exit 130" INT
      trap "kill_hard -$pgid" EXIT RETURN TERM
    wait %+
)

trap "jobs -p | xargs -r -n 1 kill --" EXIT

for TEST_NAME in $TEST_NAMES; do
    dotnet build $TEST_NAME || {
        echo "$TEST_NAME: build error." >&2
        test_fail=$(($test_fail + 1))
        test_list="$test_list$TEST_NAME ... failed: build error\n"
        continue
    }

    SOURCE_FILES=""
    for file in `find $TEST_NAME \! -path "$TEST_NAME/obj/*" -type f -name "*.cs"`; do
        SOURCE_FILES="${SOURCE_FILES}${file};"
    done

    # Check, that test shell run in terminal (returns 0 (succeeds), if the descriptors are hooked up to a terminal).
    test -t 0 -a -t 1 -a -t 2
    # Skip CLI tests on MacOS (kernel "Darwin") in jenkins.
    if [[ "$?" != "0" ]] && [[ $TEST_NAME == CLI* ]] && [[ "$(uname)" == "Darwin" ]] ;
    then
        continue
    fi

    if [[ $TEST_NAME == CLI* ]] ;
    then
        ./run_cli_test.sh "$NETCOREDBG" "$TEST_NAME" "$TEST_NAME/bin/Debug/netcoreapp3.1/$TEST_NAME.dll" "$TEST_NAME/commands.txt"
    else
        PROTO="mi"
        if  [[ $TEST_NAME == VSCode* ]] ;
        then
            PROTO="vscode"
        fi

        test_timeout $TIMEOUT dotnet run --project TestRunner -- \
            --local $NETCOREDBG \
            --proto $PROTO \
            --test $TEST_NAME \
            --sources "$SOURCE_FILES" \
            --assembly $TEST_NAME/bin/Debug/netcoreapp3.1/$TEST_NAME.dll \
            "${LOGOPTS[@]}"
    fi


    res=$?

    if [ "$res" -ne "0" ]; then
        test_fail=$(($test_fail + 1))
        test_list="$test_list$TEST_NAME ... failed res=$res\n"
        test_xml+="            <testcase name=\"$TEST_NAME\"><failure></failure></testcase>\n"
    else
        test_pass=$(($test_pass + 1))
        test_list="$test_list$TEST_NAME ... passed\n"
        test_xml+="            <testcase name=\"$TEST_NAME\"></testcase>\n"
    fi
done

if [[ $code_coverage_report == true ]]; then
     lcov --capture --derive-func-data --gcov-tool $PWD/llvm-gcov.sh --directory $OBJS_DIR --output-file coverage.info
     cd ..
     lcov --remove test-suite/coverage.info $PWD/'.coreclr/*' $PWD/'build/*' '/usr/*' $PWD/'third_party/*' -o coverage.info
     genhtml  -o ./cov_html coverage.info
     zip -r coverage.zip cov_html/ coverage.info
     cd -
fi

if [[ $generate_report == true ]]; then
    #Generate xml test file to current directory
    generate_xml "${XML_ABS_PATH}" "${test_xml}"
    zip test.zip test-results.xml
fi

echo ""
echo -e $test_list
echo "Total tests: $(($test_pass + $test_fail)). Passed: $test_pass. Failed: $test_fail."
