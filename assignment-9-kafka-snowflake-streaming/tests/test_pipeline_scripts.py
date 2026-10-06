"""
Tests for the pipeline orchestration: scripts/start_pipeline.ps1,
scripts/stop_pipeline.ps1, scripts/pipeline_common.ps1 and the helper
scripts/request_graceful_stop.py.

Three kinds of test:

1. Safety rules, checked by reading the PowerShell scripts as text. They
   protect the promises the scripts make: only this project's processes are
   ever stopped, each by its own process id; PostgreSQL is never managed; the
   producer is never started; nothing is deleted or reset; the services are
   started with the documented commands and in a sensible order.

2. Unit tests of the Python helper's argument handling.

3. One real test on Windows: a hidden background process, started the way the
   pipeline starts its services, is asked to stop with the helper and shuts
   down in an orderly way instead of being terminated.

No Kafka, PostgreSQL or Snowflake is needed.
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import time

import pytest

from config import settings

SCRIPTS = settings.PROJECT_ROOT / "scripts"
HELPER = SCRIPTS / "request_graceful_stop.py"


def script(name: str) -> str:
    """Return the full text of one script in the scripts folder."""
    return (SCRIPTS / name).read_text(encoding="utf-8")


def code_only(name: str) -> str:
    """Return a PowerShell script without its full-line comments.

    The safety rules below are about what a script DOES. Its comments mention
    the very things it promises not to do, so they are left out.
    """
    return "\n".join(line for line in script(name).splitlines() if not line.lstrip().startswith("#"))


COMMON = code_only("pipeline_common.ps1")
START = code_only("start_pipeline.ps1")
STOP = code_only("stop_pipeline.ps1")
ALL_ORCHESTRATION = COMMON + "\n" + START + "\n" + STOP


def load_helper():
    """Import scripts/request_graceful_stop.py as a module (it is not in a package)."""
    spec = importlib.util.spec_from_file_location("request_graceful_stop", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------------------
# 1. Safety rules
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("forbidden", ["taskkill", "/IM", "Stop-Process -Name", "Get-Process -Name", "killall", "wmic"])
def test_no_process_is_ever_stopped_by_image_name(forbidden):
    """Stopping "java.exe" or "python.exe" in general could kill unrelated programs."""
    assert forbidden.lower() not in ALL_ORCHESTRATION.lower()


def test_processes_are_ended_only_by_their_own_process_id():
    """Every Stop-Process call names one specific process id."""
    calls = re.findall(r"Stop-Process[^\n]*", ALL_ORCHESTRATION)
    assert calls, "expected the fallback Stop-Process call"
    assert all("-Id $ProcessId" in call for call in calls)


def test_a_process_is_ended_only_after_it_was_asked_to_stop():
    """The orderly stop request comes first; ending the process is the fallback."""
    body = COMMON[COMMON.index("function Stop-ProjectProcess"):COMMON.index("function Stop-PythonService")]
    assert body.index("Request-GracefulStop $ProcessId $StopEvent") < body.index("Stop-Process -Id $ProcessId")
    assert "Wait-ProcessExit $ProcessId $Seconds" in body


def test_services_are_recognised_by_something_specific_to_this_project():
    """Python services by "-m <module>" or the PID file; Java services by their main class."""
    assert "'-m\\s+' + [regex]::Escape($Service.Module)" in COMMON
    assert "Get-ServicePidPath $Service" in COMMON
    assert "*ConnectStandalone*" in COMMON
    # The broker is found by the existing helper (main class kafka.Kafka).
    assert "Get-KafkaProcess" in STOP
    assert "*kafka.Kafka*" in code_only("kafka_common.ps1")


@pytest.mark.parametrize("forbidden", ["Stop-Service", "Start-Service", "Restart-Service", "Set-Service", "pg_ctl", "postgresql-x64"])
def test_postgresql_is_never_managed(forbidden):
    """PostgreSQL is only looked at (does it answer?); it is never started, stopped or restarted."""
    assert forbidden.lower() not in ALL_ORCHESTRATION.lower()


def test_postgresql_is_only_checked_for_reachability():
    """The one PostgreSQL-related action is a TCP connection attempt."""
    body = COMMON[COMMON.index("function Get-PostgresState"):COMMON.index("function Write-StatusLine")]
    assert "System.Net.Sockets.TcpClient" in body
    assert "psql" not in ALL_ORCHESTRATION.lower()


def test_the_producer_is_never_started():
    """The producer generates demo data and must only be run by hand."""
    assert "producer" not in ALL_ORCHESTRATION.lower()


@pytest.mark.parametrize(
    "forbidden",
    ["--delete", "--alter", "--reset-offsets", "reset_kafka", "Remove-Item -Recurse", "99_cdc_teardown", "99_teardown",
     "pg_drop_replication_slot", "connect.offsets", "kafka-delete-records", "DROP "],
)
def test_nothing_is_deleted_or_reset(forbidden):
    """No topic, Kafka data, consumer group, Debezium offset or replication slot is ever removed."""
    assert forbidden.lower() not in ALL_ORCHESTRATION.lower()


def test_only_log_and_pid_files_of_the_services_are_removed():
    """The only files the scripts delete are their own PID files."""
    removals = re.findall(r"Remove-Item[^\n]*", ALL_ORCHESTRATION)
    assert removals and all("Get-ServicePidPath $Service" in removal for removal in removals)


def test_existing_scripts_are_reused_for_kafka_connect_and_topics():
    """The broker, Kafka Connect and topic creation go through the scripts that already exist."""
    assert '"$PSScriptRoot\\start_kafka.ps1" -Background' in START
    assert '"$PSScriptRoot\\start_connect.ps1" -Background' in START
    assert '"$PSScriptRoot\\create_topics.ps1" -IncludeCdc' in START
    # Kafka Connect's startup logic is not copied into the new scripts.
    assert "connect-standalone.bat" not in ALL_ORCHESTRATION
    assert "kafka-server-start.bat" not in ALL_ORCHESTRATION


def test_python_services_use_the_documented_commands():
    """The consumer and the bridge are started as "python -m consumer.consumer" and "python -m cdc.bridge"."""
    assert "Module = 'cdc.bridge'" in COMMON
    assert "Module = 'consumer.consumer'" in COMMON
    assert "-ArgumentList '-m', $Service.Module" in COMMON
    assert "-WorkingDirectory $ProjectRoot" in COMMON


def test_services_run_hidden_with_their_output_in_log_files():
    """No console windows are opened, and each service's log goes to a file."""
    assert "-WindowStyle Hidden" in COMMON
    assert "-RedirectStandardError $logPath" in COMMON
    assert "LogBase = 'cdc-bridge'" in COMMON and "LogBase = 'consumer'" in COMMON


def test_runtime_files_are_written_outside_the_repository():
    """Logs and PID files go to the Kafka run-logs folder, so they cannot be committed."""
    assert "$PipelineLogDir = $KafkaRunLogs" in COMMON
    assert "$ProjectRoot" not in COMMON[COMMON.index("function Get-ServiceLogPath"):COMMON.index("function Test-ConnectPort")]


def test_consumer_groups_match_the_application_settings():
    """The groups used to notice an already-running service are the application's own groups."""
    assert f"Get-DotEnvValue 'CDC_BRIDGE_GROUP_ID' '{settings.CDC_BRIDGE_GROUP_ID}'" in COMMON
    assert f"Get-DotEnvValue 'KAFKA_GROUP_ID' '{settings.KAFKA_GROUP_ID}'" in COMMON
    assert f"$ConnectorName   = '{settings.CONNECT_CONNECTOR_NAME}'" in COMMON


def test_consumer_groups_are_only_read():
    """The group check describes a group; it never changes one."""
    assert "'--describe', '--group', $Group, '--members'" in COMMON
    assert "--execute" not in ALL_ORCHESTRATION


def test_duplicate_protection_checks_before_every_start():
    """A Python service is started only when it is neither running here nor connected from elsewhere."""
    loop = START[START.index("foreach ($service in @($ConsumerService, $BridgeService))"):]
    state_check, start_call = loop.index("Get-ServiceState $service"), loop.index("Start-PythonService $service")
    assert state_check < start_call
    assert "if ($state -eq 'running')" in loop and "if ($state -eq 'foreign')" in loop
    # Both "already running" branches leave the loop iteration before the start call.
    assert loop[:start_call].count("continue") >= 3


def test_broker_and_connect_are_started_only_when_not_listening():
    """The broker and Kafka Connect are started only if their port does not answer."""
    assert START.index("if (Test-BrokerPort)") < START.index("start_kafka.ps1")
    assert START.index("if (-not (Test-ConnectPort))") < START.index("start_connect.ps1")


def test_start_order_is_broker_connect_consumer_bridge():
    """Each service is started after the thing it depends on."""
    positions = [
        START.index("start_kafka.ps1"),
        START.index("start_connect.ps1"),
        START.index("@($ConsumerService, $BridgeService)"),
    ]
    assert positions == sorted(positions)


def test_stop_order_is_bridge_consumer_connect_broker():
    """Services are stopped in the reverse order, so none is cut off from what it depends on."""
    positions = [
        STOP.index("@($BridgeService, $ConsumerService)"),
        STOP.index("Get-ConnectProcess"),
        STOP.index("Get-KafkaProcess"),
    ]
    assert positions == sorted(positions)


def test_broker_is_not_stopped_while_something_still_uses_it():
    """If a dependent service could not be stopped, the broker is left running."""
    assert "$dependentsRunning.Count -gt 0" in STOP
    assert STOP.index("$dependentsRunning.Count -gt 0") < STOP.index("Get-KafkaProcess")
    assert "[switch]$KeepBroker" in STOP


def test_an_already_stopped_service_counts_as_success():
    """Stopping something that is not running is not an error."""
    assert "return 'already stopped'" in COMMON
    assert "$outcome -in 'already stopped', 'graceful', 'forced'" in STOP
    assert "'already stopped' { return 'STOPPED (was not running)' }" in STOP


def test_scripts_report_ready_and_stopped_and_failures_with_log_paths():
    """The summaries the user sees, and the pointer to the log when something fails."""
    assert "Pipeline Status: READY" in START and "Pipeline Status: NOT READY" in START
    assert "Pipeline Status: STOPPED" in STOP
    assert "see $($results[$name].Log)" in START
    for name in ("Kafka Broker", "Kafka Connect", "CDC Bridge", "Snowflake Consumer"):
        assert name in ALL_ORCHESTRATION


def test_exit_codes_tell_success_from_failure():
    """0 when the pipeline is ready or stopped, 1 otherwise, so the scripts can be used from other scripts."""
    for text in (START, STOP):
        assert "exit 0" in text and "exit 1" in text


@pytest.mark.parametrize("name", ["start_pipeline.ps1", "stop_pipeline.ps1", "pipeline_common.ps1"])
def test_every_script_starts_with_a_header_comment(name):
    """Each script explains at the top what it is for."""
    lines = script(name).splitlines()
    assert lines[0].startswith("# ====")
    assert lines[1] == f"# {name}"


@pytest.mark.parametrize("name", ["start_pipeline.ps1", "stop_pipeline.ps1", "pipeline_common.ps1"])
def test_every_function_has_a_comment(name):
    """Each PowerShell function begins with a comment saying what it does."""
    lines = script(name).splitlines()
    for index, line in enumerate(lines):
        if line.startswith("function "):
            assert lines[index + 1].lstrip().startswith("#"), f"{name}: {line.split('(')[0]} has no comment"


def test_generated_runtime_files_are_git_ignored():
    """Logs and PID files are ignored, in case the log folder is ever pointed inside the repository."""
    ignore = (settings.PROJECT_ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
    for pattern in ("run-logs/", "*.log", "*.pid", ".env"):
        assert pattern in ignore


# ---------------------------------------------------------------------------
# 2. The helper's argument handling
# ---------------------------------------------------------------------------

def test_helper_accepts_a_process_id_and_defaults_to_ctrl_c():
    """A single whole number is the process id; without an event, Ctrl+C is sent."""
    helper = load_helper()
    assert helper.parse_arguments(["1234"]) == (1234, helper.CTRL_C_EVENT)


def test_helper_accepts_either_event_by_name():
    """The event can be named: ctrl-c for Java services, ctrl-break for Python services."""
    helper = load_helper()
    assert helper.parse_arguments(["1234", "ctrl-c"]) == (1234, helper.CTRL_C_EVENT)
    assert helper.parse_arguments(["1234", "ctrl-break"]) == (1234, helper.CTRL_BREAK_EVENT)
    assert (helper.CTRL_C_EVENT, helper.CTRL_BREAK_EVENT) == (0, 1)        # the Windows values


@pytest.mark.parametrize(
    "arguments",
    [[], ["1", "ctrl-c", "x"], ["abc"], ["12.5"], ["0"], ["-4"], [""], ["1234", "kill"], ["1234", "CTRL-C"], ["1234", "2"]],
)
def test_helper_rejects_anything_else(arguments):
    """Missing or surplus arguments, a bad process id or an unknown event are refused."""
    with pytest.raises(ValueError):
        load_helper().parse_arguments(arguments)


def test_python_services_are_stopped_with_ctrl_break_and_java_services_with_ctrl_c():
    """Ctrl+Break for the consumer and the bridge; Ctrl+C (the default) for Kafka and Kafka Connect."""
    python_stop = COMMON[COMMON.index("function Stop-PythonService"):COMMON.index("function Get-ConnectorState")]
    assert "-StopEvent 'ctrl-break'" in python_stop
    # The Java services are stopped from stop_pipeline.ps1 without naming an event.
    assert "StopEvent" not in STOP
    assert "[string]$StopEvent = 'ctrl-c'" in COMMON


def test_both_python_services_handle_ctrl_break():
    """The stop request relies on the services registering a handler for Ctrl+Break (SIGBREAK)."""
    for module in ("consumer/consumer.py", "cdc/bridge.py"):
        source = (settings.PROJECT_ROOT / module).read_text(encoding="utf-8")
        assert "signal.signal(signal.SIGBREAK, request_stop)" in source


def test_helper_reports_wrong_usage_with_its_own_exit_code():
    """Wrong usage ends with exit code 1 and delivers nothing."""
    result = subprocess.run([sys.executable, str(HELPER)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 1
    assert "usage" in result.stderr


def test_helper_does_nothing_outside_windows(monkeypatch):
    """On another operating system the helper only reports that it cannot work there."""
    helper = load_helper()
    monkeypatch.setattr(sys, "platform", "linux")
    assert helper.send_console_event(1234) == helper.EXIT_NOT_WINDOWS


def test_helper_never_terminates_a_process():
    """The helper only delivers a request; it contains no call that ends a process."""
    source = HELPER.read_text(encoding="utf-8")
    code = "\n".join(line for line in source.split('"""')[-1].splitlines() if not line.lstrip().startswith("#"))
    for forbidden in ("TerminateProcess", "os.kill", "taskkill", ".terminate(", ".kill("):
        assert forbidden not in code


# ---------------------------------------------------------------------------
# 3. A real orderly stop of a hidden background process (Windows only)
# ---------------------------------------------------------------------------

windows_only = pytest.mark.skipif(sys.platform != "win32", reason="console control events exist only on Windows")

# A tiny service that behaves like the pipeline's Python services: it installs
# its signal handlers the same way, runs until asked to stop, and then
# performs an orderly shutdown that leaves a marker file behind.
STAND_IN_SERVICE = '''
import signal, sys, threading, time
stop = threading.Event()
def request_stop(signum, frame):
    stop.set()
signal.signal(signal.SIGINT, request_stop)
if hasattr(signal, "SIGBREAK"):
    signal.signal(signal.SIGBREAK, request_stop)
open(sys.argv[1], "w").write("running")
while not stop.is_set():
    time.sleep(0.2)
open(sys.argv[2], "w").write("orderly shutdown completed")
'''


def start_hidden(arguments: list[str]) -> subprocess.Popen:
    """Start a process with its own hidden console, as Start-Process -WindowStyle Hidden does."""
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0                                   # SW_HIDE
    return subprocess.Popen(
        arguments, creationflags=subprocess.CREATE_NEW_CONSOLE, startupinfo=startup,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def wait_for(path, seconds: float) -> bool:
    """Wait until a file exists; return whether it appeared in time."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if path.exists():
            return True
        time.sleep(0.1)
    return path.exists()


@windows_only
def test_hidden_background_process_shuts_down_in_an_orderly_way(tmp_path):
    """The helper makes a hidden service run its own shutdown; the service is not terminated."""
    service_file, running, finished = tmp_path / "service.py", tmp_path / "running", tmp_path / "finished"
    service_file.write_text(STAND_IN_SERVICE, encoding="utf-8")
    service = start_hidden([sys.executable, str(service_file), str(running), str(finished)])
    try:
        assert wait_for(running, 20), "the stand-in service did not start"

        # The helper runs in its own hidden process and sends Ctrl+Break,
        # exactly as stop_pipeline.ps1 does for the consumer and the bridge.
        helper = start_hidden([sys.executable, str(HELPER), str(service.pid), "ctrl-break"])
        assert helper.wait(30) == 0, "the stop request was not delivered"

        assert service.wait(20) == 0, "the service did not exit normally"
        # The marker is written only by the service's own shutdown code.
        assert finished.read_text(encoding="utf-8") == "orderly shutdown completed"
    finally:
        if service.poll() is None:
            service.kill()


@windows_only
def test_helper_reports_a_process_it_cannot_reach():
    """A process id that does not exist cannot be attached to; nothing is signalled."""
    helper = start_hidden([sys.executable, str(HELPER), "4194300"])    # far above any real process id here
    assert helper.wait(30) == load_helper().EXIT_CANNOT_ATTACH
