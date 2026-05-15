"""Test command input validation"""

import pytest
import re

K8S_NAME_RE = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")


def require_k8s_name(value, label):
    """Validate that a value is a valid Kubernetes resource name."""
    value = str(value or "").strip()
    if not value or not K8S_NAME_RE.fullmatch(value):
        raise ValueError(f"Invalid {label}")
    return value


class TestK8sNameValidation:
    def test_valid_k8s_names(self):
        """Valid Kubernetes resource names should pass."""
        assert require_k8s_name('my-app', 'name') == 'my-app'
        assert require_k8s_name('nginx', 'name') == 'nginx'
        assert require_k8s_name('api-server-7d9f6', 'name') == 'api-server-7d9f6'
        assert require_k8s_name('a', 'name') == 'a'
        assert require_k8s_name('abc123', 'name') == 'abc123'

    def test_invalid_k8s_names(self):
        """Invalid Kubernetes resource names should raise ValueError."""
        with pytest.raises(ValueError):
            require_k8s_name('', 'name')
        with pytest.raises(ValueError):
            require_k8s_name(None, 'name')
        with pytest.raises(ValueError):
            require_k8s_name('MyApp', 'name')  # uppercase
        with pytest.raises(ValueError):
            require_k8s_name('my_app', 'name')  # underscore
        with pytest.raises(ValueError):
            require_k8s_name('my-app-', 'name')  # ends with dash
        with pytest.raises(ValueError):
            require_k8s_name('-app', 'name')  # starts with dash
        with pytest.raises(ValueError):
            require_k8s_name('my app', 'name')  # space
        with pytest.raises(ValueError):
            require_k8s_name('my*app', 'name')  # special char