#!/bin/zsh
# Build "Gõ Tắt" cho Windows (chạy được ngay trên macOS), ra GoTat-Windows.zip
set -e
cd "$(dirname "$0")"

DOTNET="$(command -v dotnet || echo "$HOME/.dotnet/dotnet")"
if [ ! -x "$DOTNET" ]; then
    echo "Chưa có .NET SDK. Cài bằng lệnh:"
    echo "  curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 8.0 --install-dir ~/.dotnet"
    exit 1
fi

OUT="build/windows"
rm -rf "$OUT" GoTat-Windows.zip
"$DOTNET" publish windows/GoTat.csproj -c Release -o "$OUT" --nologo

# Nén thành zip để gửi đi
(cd "$OUT" && zip -q -9 ../../GoTat-Windows.zip GoTat.exe)
echo "Đã build: $(pwd)/$OUT/GoTat.exe"
echo "File gửi đi: $(pwd)/GoTat-Windows.zip"
