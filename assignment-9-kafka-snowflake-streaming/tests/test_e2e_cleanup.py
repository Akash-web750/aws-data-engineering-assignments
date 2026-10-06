"""
Unit tests for the cleanup rule of the live end-to-end test (tests/test_e2e.py).

Deleting a Kafka topic crashes the local broker on Windows, so the live test
must not delete its topics there. These tests need no broker and no Snowflake;
they only check the rule and that the cleanup obeys it.
"""

from __future__ import annotations

import pytest

import test_e2e
from test_e2e import Pipeline, topic_deletion_is_safe


class RecordingAdmin:
    """Stands in for the Kafka AdminClient and records deletion requests."""

    def __init__(self) -> None:
        """No deletion requested yet."""
        self.deleted: list[list[str]] = []

    def delete_topics(self, topics: list[str]) -> dict:
        """Remember the request; return no futures to wait on."""
        self.deleted.append(list(topics))
        return {}


def make_pipeline() -> tuple[Pipeline, RecordingAdmin]:
    """Build a Pipeline object WITHOUT running its constructor.

    The real constructor connects to Kafka and Snowflake. ``delete_topics``
    only needs the topic names and the admin client, so those are set by hand.
    """
    pipeline = Pipeline.__new__(Pipeline)
    pipeline.topic = "order_events_e2e_test"
    pipeline.dlq_topic = "order_events_e2e_test_dlq"
    pipeline.admin = RecordingAdmin()
    return pipeline, pipeline.admin


@pytest.mark.parametrize("platform", ["win32", "win64", "windows"])
def test_topic_deletion_is_not_safe_on_windows(platform):
    """Any Windows platform string means: do not delete topics."""
    assert topic_deletion_is_safe(platform) is False


@pytest.mark.parametrize("platform", ["linux", "darwin", "freebsd14"])
def test_topic_deletion_is_safe_elsewhere(platform):
    """Other operating systems can rename a folder with open files, so deletion is fine."""
    assert topic_deletion_is_safe(platform) is True


def test_cleanup_does_not_delete_topics_on_windows(monkeypatch):
    """On Windows the cleanup sends NO deletion request to Kafka and reports that it skipped."""
    monkeypatch.setattr(test_e2e, "topic_deletion_is_safe", lambda: False)
    pipeline, admin = make_pipeline()
    assert pipeline.delete_topics() is False
    assert admin.deleted == []


def test_cleanup_still_deletes_topics_where_it_is_safe(monkeypatch):
    """Elsewhere both dedicated topics are deleted, as before."""
    monkeypatch.setattr(test_e2e, "topic_deletion_is_safe", lambda: True)
    pipeline, admin = make_pipeline()
    assert pipeline.delete_topics() is True
    assert admin.deleted == [["order_events_e2e_test", "order_events_e2e_test_dlq"]]
