"""Test filebrowser path validation"""

import pytest
import sys
import os
import posixpath

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


FILEBROWSER_BASE_PATH = '/srv'


def _validate_fb_path(path):
    """Validate filebrowser path is within allowed directory."""
    path_str = str(path or "").lstrip("/")
    if '..' in path_str or '\x00' in path_str:
        return False
    normalized = posixpath.normpath("/" + path_str)
    return normalized == FILEBROWSER_BASE_PATH or normalized.startswith(FILEBROWSER_BASE_PATH + "/")


class TestFileBrowserPathValidation:
    def test_valid_root_path(self):
        """Root /srv should be allowed."""
        assert _validate_fb_path('/srv') is True
        assert _validate_fb_path('srv') is True

    def test_valid_subdirectory(self):
        """Subdirectories of /srv should be allowed."""
        assert _validate_fb_path('/srv/config') is True
        assert _validate_fb_path('/srv/config/settings.ini') is True
        assert _validate_fb_path('/srv/nested/deep/path') is True

    def test_invalid_false_prefix(self):
        """Paths that start with /srv but are not under /srv should be rejected."""
        assert _validate_fb_path('/srv2') is False
        assert _validate_fb_path('/srv2/config') is False
        assert _validate_fb_path('/srvbackup') is False

    def test_invalid_parent_traversal(self):
        """Paths with .. should be rejected."""
        assert _validate_fb_path('/srv/../etc') is False
        assert _validate_fb_path('/srv/config/../../../etc') is False
        assert _validate_fb_path('../settings.yaml') is False

    def test_invalid_absolute_path(self):
        """Paths outside /srv should be rejected."""
        assert _validate_fb_path('/etc') is False
        assert _validate_fb_path('/home') is False
        assert _validate_fb_path('/') is False

    def test_invalid_null_byte(self):
        """Paths with null bytes should be rejected."""
        assert _validate_fb_path('/srv/config\x00') is False
        assert _validate_fb_path('/srv/../etc\x00') is False