#!/usr/bin/env bats
# Unit-Tests für die Host-Skripte (ohne Docker, ohne Netz)

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../host/lib/common.sh
  . "$ROOT/host/lib/common.sh"
  FACTORY_HOST_ENV=/nonexistent load_host_env
}

@test "Namen, Umgebungen und Images werden streng geprüft" {
  valid_name shop
  valid_name shop-2
  ! valid_name Shop
  ! valid_name "shop;rm"
  ! valid_name -shop
  valid_env staging
  valid_env production
  ! valid_env test
  valid_image "ghcr.io/o/r@sha256:$(printf 'a%.0s' {1..64})"
  ! valid_image "ghcr.io/o/r:latest"
  ! valid_image "ghcr.io/o/r@sha256:abc"
}

@test "Ports, Domains, Snapshots" {
  valid_port 5101
  ! valid_port 80
  ! valid_port 70000
  valid_domain staging.example.org
  ! valid_domain "example.org; reload"
  ! valid_domain localhost
  valid_snapshot latest
  valid_snapshot 2026-11-24
  valid_snapshot 2026-11-24T13:45
  ! valid_snapshot yesterday
}

@test "allowed: Stern erlaubt alles, Liste nur die genannten Apps" {
  allowed shop-staging "*"
  allowed shop-staging "shop-staging,shop-production"
  ! allowed shop-production "shop-staging"
  ! allowed shop-staging ""
}

@test "commit_matches akzeptiert kurze und lange SHAs, aber nicht zu kurze" {
  commit_matches 0123456789abcdef0123456789abcdef01234567 0123456
  commit_matches 0123456 0123456789abcdef0123456789abcdef01234567
  ! commit_matches 0123456789abcdef 0123
  ! commit_matches 0123456789abcdef fedcba9
  ! commit_matches "" 0123456
}

@test "health_ok: ok und degraded mit richtigem Commit sind gesund" {
  health_ok '{"status":"ok","commit":"0123456789"}' 0123456789
  health_ok '{"status":"degraded","commit":"0123456789"}' 0123456
  ! health_ok '{"status":"down","commit":"0123456789"}' 0123456789
  ! health_ok '{"status":"ok","commit":"fffffff999"}' 0123456789
  ! health_ok '{"status":"ok"}' 0123456789
  ! health_ok 'kein json' 0123456789
}

@test "with-secrets exportiert jede Datei als Variable, auch mehrzeilig" {
  dir="$BATS_TEST_TMPDIR/secrets"
  mkdir -p "$dir"
  printf 'wert1' > "$dir/EINS"
  printf 'zeile1\nzeile2\n' > "$dir/MEHRZEILIG"
  printf 'x' > "$dir/UNGUELTIG-NAME"
  run env SECRETS_PATH="$dir" sh "$ROOT/host/bin/with-secrets" sh -c 'printf "%s|%s|%s" "$EINS" "$MEHRZEILIG" "${UNGUELTIG:-leer}"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'wert1|zeile1\nzeile2\n|leer')" ]
}

@test "with-secrets ohne Befehl bricht ab" {
  run sh "$ROOT/host/bin/with-secrets"
  [ "$status" -eq 64 ]
}

@test "factory-host lehnt unbekannte SSH-Aktionen ab" {
  run env FACTORY_HOST_ENV=/nonexistent SSH_ORIGINAL_COMMAND="bash -i" bash "$ROOT/host/bin/factory-host" --ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Nicht erlaubt"* ]]
}

@test "factory-host lehnt Bündel mit falschem Protokoll ab" {
  b="$BATS_TEST_TMPDIR/b"; mkdir -p "$b"
  echo '{}' > "$b/delivery.json"
  echo '{"protocol":99,"verb":"status","project":"demo","environment":"staging","commit":"0123456"}' > "$b/release.json"
  run bash -c "tar -C '$b' -czf - . | env FACTORY_HOST_ENV=/nonexistent SSH_ORIGINAL_COMMAND=status bash '$ROOT/host/bin/factory-host' --ssh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Protokoll"* ]]
}

@test "factory-host lehnt Bündel mit Symlinks ab" {
  b="$BATS_TEST_TMPDIR/b2"; mkdir -p "$b"
  ln -s /etc/passwd "$b/compose.yml"
  echo '{}' > "$b/delivery.json"
  echo '{"protocol":1,"verb":"status","project":"demo","environment":"staging","commit":"0123456"}' > "$b/release.json"
  run bash -c "tar -C '$b' -czf - . | env FACTORY_HOST_ENV=/nonexistent SSH_ORIGINAL_COMMAND=status bash '$ROOT/host/bin/factory-host' --ssh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"anderes als Dateien"* ]]
}

@test "factory-host: --allow beschränkt den Schlüssel auf bestimmte Apps" {
  b="$BATS_TEST_TMPDIR/b3"; mkdir -p "$b"
  echo '{}' > "$b/delivery.json"
  echo '{"protocol":1,"verb":"status","project":"demo","environment":"production","commit":"0123456"}' > "$b/release.json"
  run bash -c "tar -C '$b' -czf - . | env FACTORY_HOST_ENV=/nonexistent SSH_ORIGINAL_COMMAND=status bash '$ROOT/host/bin/factory-host' --ssh --allow demo-staging"
  [ "$status" -ne 0 ]
  [[ "$output" == *"darf demo-production nicht"* ]]
}
