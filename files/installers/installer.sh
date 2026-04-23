#!/bin/bash

set -e

detect_aur_helper() {
    for helper in yay paru trizen pamac; do
        if command -v "$helper" &>/dev/null && [ -x "$(command -v "$helper")" ]; then
            echo "$helper"
            return 0
        fi
    done
    return 1
}

AUR_HELPER=$(detect_aur_helper)

echo "=== Detected AUR helper: ${AUR_HELPER:-none} ==="

echo "=== Checking for uv (Python version manager) ==="
if ! command -v uv &>/dev/null; then
    python3 -m pip install --user uv 2>/dev/null || true
fi
if [ -x "$HOME/.local/bin/uv" ]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

echo "=== Installing git ==="
if ! pacman -Q git &>/dev/null; then
    sudo pacman -S --noconfirm git
fi

echo "=== Installing make ==="
if ! pacman -Q make &>/dev/null; then
    sudo pacman -S --noconfirm make
fi

echo "=== Installing ollama ==="
if ! command -v ollama &>/dev/null; then
    if ! pacman -S --noconfirm ollama 2>/dev/null; then
        if [ "$EUID" -ne 0 ] && [ -n "$AUR_HELPER" ] && [ -w "/var/cache/pacman/pkg" ]; then
            sudo $AUR_HELPER -S --noconfirm ollama-bin
        else
            echo "Installing ollama from website..."
            curl -fsSL https://ollama.com/install.sh | sh
        fi
    fi
fi

if ! command -v ollama &>/dev/null; then
    echo "ERROR: ollama not found after installation"
    exit 1
fi
echo "=== ollama installed: $(command -v ollama) ==="

echo "=== Installing python-poetry ==="
if ! command -v poetry &>/dev/null; then
    if ! pacman -S --noconfirm python-poetry 2>/dev/null; then
        if [ "$EUID" -ne 0 ] && [ -n "$AUR_HELPER" ] && [ -w "/var/cache/pacman/pkg" ]; then
            sudo $AUR_HELPER -S --noconfirm python-poetry-git
        else
            echo "Installing poetry via pip..."
            python3 -m pip install --user poetry 2>/dev/null || {
                echo "Installing poetry via official installer..."
                curl -sSL https://install.python-poetry.org | python3 - --version 2.3.4 || true
            }
        fi
    fi
fi

echo "=== Adding poetry to PATH if needed ==="
if ! command -v poetry &>/dev/null; then
    if [ -x "$HOME/.local/bin/poetry" ]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
fi

if ! command -v poetry &>/dev/null; then
    echo "ERROR: poetry not found after installation"
    exit 1
fi
echo "=== poetry installed: $(command -v poetry) ==="

echo "=== Cloning private-gpt repository ==="
if ! rm -rf private-gpt 2>/dev/null; then
    echo "WARNING: Could not remove existing directory, continuing..."
fi
if ! git clone https://github.com/zylon-ai/private-gpt 2>/dev/null; then
    echo "ERROR: Failed to clone repository"
    exit 1
fi
cd private-gpt

echo "=== Reading Python version requirement from pyproject.toml ==="
PYTHON_REQUIREMENT_RAW=$(grep -E "^python = " pyproject.toml 2>/dev/null || true)
if [ -n "$PYTHON_REQUIREMENT_RAW" ]; then
    PYTHON_REQUIREMENT=$(echo "$PYTHON_REQUIREMENT_RAW" | sed 's/python = "//; s/"$//')
else
    PYTHON_REQUIREMENT=">=3.11"
fi
echo "PrivateGPT requires: $PYTHON_REQUIREMENT"

PYTHON_MINOR_RAW=$(echo "$PYTHON_REQUIREMENT" | grep -oP '\d+\.\d+' | head -1 || true)
if [ -n "$PYTHON_MINOR_RAW" ]; then
    PYTHON_MINOR="$PYTHON_MINOR_RAW"
else
    PYTHON_MINOR="3.11"
fi
echo "Required Python version: $PYTHON_MINOR"

PYTHON_BIN=""
for bin in "/usr/bin/python${PYTHON_MINOR}" "/usr/bin/python${PYTHON_MINOR}.0" "$HOME/.local/bin/python${PYTHON_MINOR}" "$HOME/.local/bin/python${PYTHON_MINOR}.0"; do
    if [ -x "$bin" ]; then
        PYTHON_BIN="$bin"
        break
    fi
done

if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
    echo "=== Installing python${PYTHON_MINOR} ==="
    if ! pacman -S --noconfirm "python${PYTHON_MINOR}" 2>/dev/null; then
        if [ "$EUID" -ne 0 ] && [ -n "$AUR_HELPER" ] && [ -w "/var/cache/pacman/pkg" ]; then
            if ! sudo $AUR_HELPER -S --noconfirm "python${PYTHON_MINOR}-git" 2>/dev/null; then
                if command -v uv &>/dev/null; then
                    echo "Installing python${PYTHON_MINOR} via uv..."
                    uv python install "${PYTHON_MINOR}" 2>/dev/null || {
                        echo "ERROR: Could not install python${PYTHON_MINOR}"
                        exit 1
                    }
                else
                    echo "ERROR: Could not install python${PYTHON_MINOR}"
                    exit 1
                fi
            fi
        else
            if command -v uv &>/dev/null; then
                echo "Installing python${PYTHON_MINOR} via uv..."
                uv python install "${PYTHON_MINOR}" 2>/dev/null || {
                    echo "ERROR: Could not install python${PYTHON_MINOR}"
                    exit 1
                }
            else
                echo "ERROR: Could not install python${PYTHON_MINOR}"
                exit 1
            fi
        fi
    fi
    
    for bin in "/usr/bin/python${PYTHON_MINOR}" "/usr/bin/python${PYTHON_MINOR}.0" "$HOME/.local/bin/python${PYTHON_MINOR}" "$HOME/.local/bin/python${PYTHON_MINOR}.0"; do
        if [ -x "$bin" ]; then
            PYTHON_BIN="$bin"
            break
        fi
    done
    
    if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
        echo "ERROR: python${PYTHON_MINOR} not found after installation"
        exit 1
    fi
fi

echo "=== Using Python: $($PYTHON_BIN --version) ==="

if [ -f "settings-ollama.yaml" ] || [ -f "settings/settings-ollama.yaml" ]; then
    SETTINGS_FILE=""
    if [ -f "settings-ollama.yaml" ]; then
        SETTINGS_FILE="settings-ollama.yaml"
    elif [ -f "settings/settings-ollama.yaml" ]; then
        SETTINGS_FILE="settings/settings-ollama.yaml"
    fi
    
    LLM_MODEL_LINE=$(grep -E "^llm_model:" "$SETTINGS_FILE" 2>/dev/null || true)
    EMBEDDING_MODEL_LINE=$(grep -E "^embedding_model:" "$SETTINGS_FILE" 2>/dev/null || true)
    
    if [ -n "$LLM_MODEL_LINE" ]; then
        LLM_MODEL=$(echo "$LLM_MODEL_LINE" | sed 's/llm_model: *//')
    fi
    if [ -n "$EMBEDDING_MODEL_LINE" ]; then
        EMBEDDING_MODEL=$(echo "$EMBEDDING_MODEL_LINE" | sed 's/embedding_model: *//')
    fi
    
    echo "=== Settings file: $SETTINGS_FILE ==="
    [ -n "$LLM_MODEL" ] && echo "=== LLM Model: $LLM_MODEL ==="
    [ -n "$EMBEDDING_MODEL" ] && echo "=== Embedding Model: $EMBEDDING_MODEL ==="
else
    echo "=== WARNING: settings-ollama.yaml not found ==="
fi

echo "=== Checking ollama status ==="
if pgrep -x ollama > /dev/null 2>&1; then
    echo "=== ollama is already running ==="
    OLLAMA_PID=""
else
    echo "=== Starting ollama server ==="
    ollama serve &
    OLLAMA_PID=$!
    sleep 5
fi

if [ -n "$LLM_MODEL" ]; then
    echo "=== Pulling LLM model: $LLM_MODEL ==="
    ollama pull "$LLM_MODEL"
fi

if [ -n "$EMBEDDING_MODEL" ]; then
    echo "=== Pulling embedding model: $EMBEDDING_MODEL ==="
    ollama pull "$EMBEDDING_MODEL"
fi

echo "=== Setting up poetry environment ==="
poetry env use "$PYTHON_BIN"

echo "=== Installing Python dependencies ==="
poetry install --extras "ui llms-ollama embeddings-ollama vector-stores-qdrant"

echo "=== Running private-gpt ==="
PGPT_PROFILES=ollama make run

if [ -n "$OLLAMA_PID" ]; then
    echo "=== Cleaning up ollama server (PID: $OLLAMA_PID) ==="
    kill "$OLLAMA_PID" 2>/dev/null || true
fi