"""
Pytest configuration for the whole project.

The presence of this file in the project root makes pytest add the root to
``sys.path``, so the tests can ``import config``, ``import producer`` and
``import consumer`` no matter which folder pytest is started from.
"""
