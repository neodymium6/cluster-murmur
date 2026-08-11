{
  description = "Development environment for the cluster-murmur conversation orchestrator";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
      version = nixpkgs.lib.strings.removeSuffix "\n" (builtins.readFile ./VERSION);
      releaseSource = nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = nixpkgs.lib.fileset.unions [
          ./config
          ./lib
          ./mix.exs
          ./mix.lock
          ./priv
          ./rel
          ./VERSION
        ];
      };
      source = nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = nixpkgs.lib.fileset.unions [
          ./.github
          ./.credo.exs
          ./.dialyzer_ignore.exs
          ./.markdownlint.yaml
          ./.formatter.exs
          ./AGENTS.md
          ./config
          ./deploy
          ./DESIGN.md
          ./LICENSE
          ./README.md
          ./SECURITY.md
          ./VERSION
          ./docs
          ./lib
          ./mix.exs
          ./mix.lock
          ./priv
          ./rel
          ./test
        ];
      };
      releaseFor =
        system:
        let
          pkgs = pkgsFor.${system};
        in
        pkgs.beamPackages.mixRelease {
          pname = "cluster-murmur";
          inherit version;
          src = releaseSource;

          mixFodDeps = pkgs.beamPackages.fetchMixDeps {
            pname = "cluster-murmur-prod-deps";
            inherit version;
            src = releaseSource;
            hash = "sha256-QTch0JBsxhzoAuMXPY5Ia7O8zMNYF2YEs/2iVGTKSOk=";
          };

          EXQLITE_USE_SYSTEM = "1";
          buildInputs = [ pkgs.sqlite ];

          meta = {
            description = "Bounded observation-to-conversation orchestrator";
            homepage = "https://github.com/neodymium6/cluster-murmur";
            license = nixpkgs.lib.licenses.asl20;
            mainProgram = "cluster_murmur";
          };
        };
      containerImageFor =
        system:
        let
          pkgs = pkgsFor.${system};
          productionRelease = releaseFor system;
        in
        pkgs.dockerTools.buildLayeredImage {
          name = "cluster-murmur";
          tag = version;
          contents = [ productionRelease ];

          extraCommands = ''
            mkdir -p ./bin ./etc ./tmp ./var/lib/cluster-murmur
            ln -s ${productionRelease}/bin/cluster_murmur ./bin/cluster-murmur
            ln -s ${pkgs.tini}/bin/tini ./bin/tini
            printf '%s\n' \
              'cluster-murmur:x:65532:65532:Cluster Murmur:/tmp:/sbin/nologin' \
              > ./etc/passwd
            printf '%s\n' 'cluster-murmur:x:65532:' > ./etc/group
            chmod 0755 ./etc
            chmod 0644 ./etc/passwd ./etc/group
            chmod 0700 ./tmp ./var/lib/cluster-murmur
          '';

          fakeRootCommands = ''
            chown 65532:65532 ./tmp ./var/lib/cluster-murmur
          '';

          config = {
            User = "65532:65532";
            WorkingDir = "/";
            Entrypoint = [
              "/bin/tini"
              "--"
            ];
            Cmd = [
              "/bin/cluster-murmur"
              "start"
            ];
            Env = [
              "HOME=/tmp"
              "LANG=C.UTF-8"
              "LC_ALL=C.UTF-8"
              "RELEASE_TMP=/tmp/release"
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              "TMPDIR=/tmp"
            ];
            Labels = {
              "org.opencontainers.image.description" = "Bounded observation-to-conversation orchestrator";
              "org.opencontainers.image.licenses" = "Apache-2.0";
              "org.opencontainers.image.source" = "https://github.com/neodymium6/cluster-murmur";
              "org.opencontainers.image.title" = "Cluster Murmur";
              "org.opencontainers.image.version" = version;
            };
          };

          meta = {
            description = "Docker-compatible Cluster Murmur image archive";
            license = nixpkgs.lib.licenses.asl20;
          };
        };
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor.${system};
        in
        {
          default = pkgs.mkShell {
            ELIXIR_ERL_OPTIONS = "+fnu";
            EXQLITE_USE_SYSTEM = "1";
            MIX_REBAR3 = "${pkgs.rebar3}/bin/rebar3";

            packages = with pkgs; [
              actionlint
              beamPackages.elixir
              beamPackages.erlang
              beamPackages.hex
              gh
              git
              gitleaks
              just
              markdownlint-cli2
              nixfmt-tree
              pre-commit
              rebar3
              sqlite
            ];
          };
        }
      );

      packages = forAllSystems (
        system:
        {
          default = releaseFor system;
          cluster-murmur = releaseFor system;
        }
        // nixpkgs.lib.optionalAttrs (pkgsFor.${system}.stdenv.isLinux) {
          container-image = containerImageFor system;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor.${system};
          productionRelease = releaseFor system;
          mixDeps = pkgs.beamPackages.fetchMixDeps {
            pname = "cluster-murmur-test-deps";
            inherit version;
            src = source;
            mixEnv = "test";
            hash = "sha256-hnCZTfFYr/Z5lWUQyJiKKZwYV2K/2YRj0lfiFKBB9vQ=";
          };
        in
        {
          application =
            pkgs.runCommand "cluster-murmur-application-check"
              {
                nativeBuildInputs = [
                  pkgs.beamPackages.elixir
                  pkgs.beamPackages.erlang
                  pkgs.beamPackages.hex
                  pkgs.gnumake
                  pkgs.rebar3
                  pkgs.sqlite
                  pkgs.stdenv.cc
                ];
              }
              ''
                cp -r ${source} work
                chmod -R u+w work
                cd work
                export MIX_ENV=test
                export ELIXIR_ERL_OPTIONS="+fnu"
                export MIX_HOME="$TMPDIR/mix"
                export MIX_BUILD_PATH="$TMPDIR/build"
                export MIX_DEPS_PATH="$TMPDIR/deps"
                export MIX_REBAR3="${pkgs.rebar3}/bin/rebar3"
                export ELIXIR_MAKE_CACHE_DIR="$TMPDIR/elixir-make"
                export EXQLITE_USE_SYSTEM=1
                cp --no-preserve=mode -R ${mixDeps} "$MIX_DEPS_PATH"
                chmod -R u+w "$MIX_DEPS_PATH"
                mix format --check-formatted
                mix compile --warnings-as-errors
                mix credo --strict
                mix dialyzer --format short
                mix test
                mix escript.build
                test "$(escript ./cluster-murmur --version)" = "$(tr -d '\n' < VERSION)"
                touch "$out"
              '';

          production-release =
            pkgs.runCommand "cluster-murmur-production-release-check"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.sqlite
                ];
              }
              ''
                release_bin="${productionRelease}/bin/cluster_murmur"
                migration_root="$TMPDIR/migration-success"
                migration_database="$migration_root/cluster-murmur.sqlite3"
                mkdir -p "$migration_root"
                chmod 0700 "$migration_root"

                config_root="$TMPDIR/standalone-config"
                mkdir -p "$config_root"
                cat > "$config_root/cluster-murmur.yaml" <<'EOF'
                version: 1
                state_tracking:
                  failures_required: 3
                  successes_required: 4
                llm:
                  provider: openai_compatible
                  base_url_env: LLM_BASE_URL
                  model_env: LLM_MODEL
                  api_key_file_env: LLM_API_KEY_FILE
                  timeout: 20s
                  max_output_tokens: 300
                includes:
                  event_groups: []
                  personas: []
                  bindings: []
                  triggers: []
                  routing:
                    - routing.yaml
                EOF
                cat > "$config_root/routing.yaml" <<'EOF'
                routing:
                  default:
                    webhook_secret_file_env: DISCORD_WEBHOOK_SECRET_FILE
                EOF
                printf '%s\n' 'clearly-fake-api-key' > "$config_root/api-key"
                printf '%s\n' 'clearly-fake-observer-token' > "$config_root/observer-token"
                printf '%s\n' \
                  'https://discord.com/api/webhooks/123456789/clearly_fake_token' \
                  > "$config_root/webhook"

                export CLUSTER_MURMUR_CONFIG_PATH="$config_root/cluster-murmur.yaml"
                export CLUSTER_MURMUR_OBSERVER_MCP_URL='https://observer.example.invalid/mcp'
                export CLUSTER_MURMUR_OBSERVER_MCP_TOKEN_FILE="$config_root/observer-token"
                export LLM_BASE_URL='https://llm.example.invalid/v1'
                export LLM_MODEL='example-model'
                export LLM_API_KEY_FILE="$config_root/api-key"
                export DISCORD_WEBHOOK_SECRET_FILE="$config_root/webhook"
                export CLUSTER_MURMUR_HEALTH_PORT='45687'
                export CLUSTER_MURMUR_POLL_INTERVAL='30s'
                export CLUSTER_MURMUR_EVENT_DISPATCH_INTERVAL='30s'
                export CLUSTER_MURMUR_RECURRING_INTERVAL='30s'
                export CLUSTER_MURMUR_STOCHASTIC_INTERVAL='30s'
                export CLUSTER_MURMUR_EVENT_RETENTION_INTERVAL='1h'
                export CLUSTER_MURMUR_RESPONDER_TURN_INTERVAL='5s'
                export CLUSTER_MURMUR_RESPONDER_GENERATION_DELAY='0ms'
                export CLUSTER_MURMUR_RESPONDER_PUBLICATION_START_DELAY='1s'
                export CLUSTER_MURMUR_RESPONDER_PUBLICATION_COMPLETE_DELAY='2s'

                test -x "$release_bin"
                test ! -e "${productionRelease}/releases/COOKIE"
                test "$(CLUSTER_MURMUR_DATABASE_PATH="$migration_database" \
                  "$release_bin" eval \
                  'IO.write("#{Application.spec(:cluster_murmur, :vsn)}:#{Node.alive?()}")')" \
                  = "${version}:false"

                CLUSTER_MURMUR_DATABASE_PATH="$migration_database" \
                  "$release_bin" eval 'ClusterMurmur.Release.migrate!()'
                test "$(sqlite3 "$migration_database" \
                  "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'stochastic_schedules'")" \
                  = "stochastic_schedules"
                test "$(stat -c '%a' "$migration_database")" = "600"

                probe_nondistributed() {
                  probe_output="$(env \
                    CLUSTER_MURMUR_DATABASE_PATH="$migration_database" \
                    RELEASE_TMP="$TMPDIR/release" \
                    "$@" \
                    "$release_bin" start_iex <<'EOF'
                IO.puts("PROBE_NODE_ALIVE=#{Node.alive?()}")
                {:ok, probe_socket} = :gen_tcp.connect({127, 0, 0, 1}, 45687, [:binary, active: false], 1000)
                :ok = :gen_tcp.send(probe_socket, "GET /readyz HTTP/1.1\r\n\r\n")
                {:ok, probe_response} = :gen_tcp.recv(probe_socket, 0, 1000)
                IO.puts("PROBE_READY=#{String.starts_with?(probe_response, "HTTP/1.1 200 OK")}")
                System.stop(0)
                EOF
                  )"

                  grep -Fq "PROBE_NODE_ALIVE=false" <<< "$probe_output"
                  grep -Fq "PROBE_READY=true" <<< "$probe_output"
                }

                mkdir -p "$TMPDIR/release"
                chmod 0700 "$TMPDIR/release"
                probe_nondistributed \
                  "RELEASE_DISTRIBUTION=sname" \
                  "RELEASE_NODE=injected_release"
                probe_nondistributed "ELIXIR_ERL_OPTIONS=-sname injected_elixir"
                probe_nondistributed "ERL_AFLAGS=-sname injected_aflags"
                probe_nondistributed "ERL_FLAGS=-sname injected_flags"
                probe_nondistributed "ERL_ZFLAGS=-sname injected_zflags"

                adversarial_vm_args="$TMPDIR/adversarial.vm.args"
                cp "${productionRelease}/releases/${version}/vm.args" "$adversarial_vm_args"
                chmod 0600 "$adversarial_vm_args"
                echo "-sname injected_vm_args" >> "$adversarial_vm_args"
                probe_nondistributed "RELEASE_VM_ARGS=$adversarial_vm_args"

                rejected_database="$TMPDIR/missing/sensitive-marker.sqlite3"
                rejected_output="$TMPDIR/migration-failure.log"
                if CLUSTER_MURMUR_DATABASE_PATH="$rejected_database" \
                  "$release_bin" eval 'ClusterMurmur.Release.migrate!()' \
                  > /dev/null 2> "$rejected_output"; then
                  exit 1
                fi
                grep -q 'database migration failed' "$rejected_output"
                if grep -q 'sensitive-marker\|migration-failure' "$rejected_output"; then
                  exit 1
                fi
                touch "$out"
              '';

          repository-metadata =
            pkgs.runCommand "cluster-murmur-repository-metadata"
              {
                nativeBuildInputs = [
                  pkgs.actionlint
                  pkgs.markdownlint-cli2
                ];
              }
              ''
                cd ${source}
                actionlint .github/workflows/*.yml
                markdownlint-cli2 \
                  AGENTS.md DESIGN.md README.md SECURITY.md \
                  deploy/**/*.md docs/**/*.md
                touch "$out"
              '';

          kubernetes-example =
            pkgs.runCommand "cluster-murmur-kubernetes-example" { nativeBuildInputs = [ pkgs.kustomize ]; }
              ''
                kustomize build ${source}/deploy/kubernetes > "$out"
                grep -q 'strategy:' "$out"
                grep -q 'type: Recreate' "$out"
                grep -q 'readOnlyRootFilesystem: true' "$out"
                grep -q 'automountServiceAccountToken: false' "$out"
                grep -q 'CLUSTER_MURMUR_LLM_BASE_URL' "$out"
                grep -q 'CLUSTER_MURMUR_DISCORD_WEBHOOK_FILE' "$out"
                if grep -q 'fsGroup:' "$out"; then
                  exit 1
                fi
              '';
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          container-image =
            let
              image = containerImageFor system;
              expectedArchitecture = pkgs.go.GOARCH;
              expectedCommand = "/bin/cluster-murmur";
              expectedEntrypoint = "/bin/tini";
              expectedCertificate = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              runtimeClosure = pkgs.closureInfo {
                rootPaths = [
                  productionRelease
                  pkgs.tini
                  pkgs.cacert
                ];
              };
            in
            pkgs.runCommand "cluster-murmur-container-image-check"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.gnutar
                  pkgs.gzip
                  pkgs.jq
                  pkgs.sqlite
                ];
              }
              ''
                archive_root="$TMPDIR/archive"
                rootfs="$TMPDIR/rootfs"
                mkdir -p "$archive_root" "$rootfs"
                tar -xzf ${image} -C "$archive_root"

                config_file="$(jq -er \
                  'if length == 1 then .[0].Config else empty end' \
                  "$archive_root/manifest.json")"
                jq -e --arg version "${version}" \
                  '.[0].RepoTags == ["cluster-murmur:" + $version]' \
                  "$archive_root/manifest.json"
                jq -e --arg entrypoint "${expectedEntrypoint}" \
                  --arg command "${expectedCommand}" \
                  --arg architecture "${expectedArchitecture}" \
                  --arg version "${version}" \
                  --arg certificate "${expectedCertificate}" '
                    .architecture == $architecture and
                    .os == "linux" and
                    .config.User == "65532:65532" and
                    .config.WorkingDir == "/" and
                    .config.Entrypoint == [$entrypoint, "--"] and
                    .config.Cmd == [$command, "start"] and
                    (.config.Env | sort) == ([
                      "HOME=/tmp",
                      "LANG=C.UTF-8",
                      "LC_ALL=C.UTF-8",
                      "RELEASE_TMP=/tmp/release",
                      "SSL_CERT_FILE=" + $certificate,
                      "TMPDIR=/tmp"
                    ] | sort) and
                    .config.ExposedPorts == null and
                    .config.Volumes == null and
                    .config.Healthcheck == null and
                    .config.Labels["org.opencontainers.image.title"] ==
                      "Cluster Murmur" and
                    .config.Labels["org.opencontainers.image.version"] == $version and
                    .config.Labels["org.opencontainers.image.licenses"] ==
                      "Apache-2.0"
                  ' "$archive_root/$config_file"

                last_layer="$(jq -er '.[0].Layers[-1]' \
                  "$archive_root/manifest.json")"
                tar --numeric-owner -tvf "$archive_root/$last_layer" \
                  > "$TMPDIR/last-layer.txt"
                grep -Eq \
                  '^drwx------[[:space:]]+65532/65532[[:space:]]+.*[[:space:]]+\./tmp/$' \
                  "$TMPDIR/last-layer.txt"
                grep -Eq \
                  '^drwx------[[:space:]]+65532/65532[[:space:]]+.*[[:space:]]+\./var/lib/cluster-murmur/$' \
                  "$TMPDIR/last-layer.txt"

                jq -er '.[0].Layers[]' "$archive_root/manifest.json" |
                  while IFS= read -r layer; do
                    if ! tar -xf "$archive_root/$layer" -C "$rootfs" \
                      2> "$TMPDIR/layer-error.txt"; then
                      cat "$TMPDIR/layer-error.txt" >&2
                      exit 1
                    fi
                  done

                grep -Fxq \
                  'cluster-murmur:x:65532:65532:Cluster Murmur:/tmp:/sbin/nologin' \
                  "$rootfs/etc/passwd"
                grep -Fxq 'cluster-murmur:x:65532:' "$rootfs/etc/group"
                test -d "$rootfs/tmp"
                test -d "$rootfs/var/lib/cluster-murmur"
                test -x "$rootfs${expectedEntrypoint}"
                test -x "$rootfs${expectedCommand}"
                while IFS= read -r store_path; do
                  test -e "$rootfs$store_path"
                done < ${runtimeClosure}/store-paths

                chmod -R a-w "$rootfs"
                chmod u+w "$rootfs/tmp" "$rootfs/var/lib/cluster-murmur"
                test ! -w "$rootfs/etc"
                test ! -w "$rootfs/nix"
                test -w "$rootfs/tmp"
                test -w "$rootfs/var/lib/cluster-murmur"

                runtime_tmp="$rootfs/tmp"
                runtime_database="$rootfs/var/lib/cluster-murmur/smoke.sqlite3"
                mkdir -p "$runtime_tmp/release"
                chmod 0700 "$runtime_tmp/release"

                config_root="$runtime_tmp/standalone-config"
                mkdir -p "$config_root"
                cat > "$config_root/cluster-murmur.yaml" <<'EOF'
                version: 1
                state_tracking:
                  failures_required: 3
                  successes_required: 4
                llm:
                  provider: openai_compatible
                  base_url_env: LLM_BASE_URL
                  model_env: LLM_MODEL
                  api_key_file_env: LLM_API_KEY_FILE
                  timeout: 20s
                  max_output_tokens: 300
                includes:
                  event_groups: []
                  personas: []
                  bindings: []
                  triggers: []
                  routing:
                    - routing.yaml
                EOF
                cat > "$config_root/routing.yaml" <<'EOF'
                routing:
                  default:
                    webhook_secret_file_env: DISCORD_WEBHOOK_SECRET_FILE
                EOF
                printf '%s\n' 'clearly-fake-api-key' > "$config_root/api-key"
                printf '%s\n' 'clearly-fake-observer-token' > "$config_root/observer-token"
                printf '%s\n' \
                  'https://discord.com/api/webhooks/123456789/clearly_fake_token' \
                  > "$config_root/webhook"

                container_env=(
                  "CLUSTER_MURMUR_CONFIG_PATH=$config_root/cluster-murmur.yaml"
                  "CLUSTER_MURMUR_DATABASE_PATH=$runtime_database"
                  "CLUSTER_MURMUR_EVENT_DISPATCH_INTERVAL=30s"
                  "CLUSTER_MURMUR_EVENT_RETENTION_INTERVAL=1h"
                  "CLUSTER_MURMUR_HEALTH_PORT=45687"
                  "CLUSTER_MURMUR_OBSERVER_MCP_TOKEN_FILE=$config_root/observer-token"
                  "CLUSTER_MURMUR_OBSERVER_MCP_URL=https://observer.example.invalid/mcp"
                  "CLUSTER_MURMUR_POLL_INTERVAL=30s"
                  "CLUSTER_MURMUR_RECURRING_INTERVAL=30s"
                  "CLUSTER_MURMUR_RESPONDER_GENERATION_DELAY=0ms"
                  "CLUSTER_MURMUR_RESPONDER_PUBLICATION_COMPLETE_DELAY=2s"
                  "CLUSTER_MURMUR_RESPONDER_PUBLICATION_START_DELAY=1s"
                  "CLUSTER_MURMUR_RESPONDER_TURN_INTERVAL=5s"
                  "CLUSTER_MURMUR_STOCHASTIC_INTERVAL=30s"
                  "DISCORD_WEBHOOK_SECRET_FILE=$config_root/webhook"
                  "HOME=$runtime_tmp"
                  "LANG=C.UTF-8"
                  "LC_ALL=C.UTF-8"
                  "LLM_API_KEY_FILE=$config_root/api-key"
                  "LLM_BASE_URL=https://llm.example.invalid/v1"
                  "LLM_MODEL=example-model"
                  "RELEASE_TMP=$runtime_tmp/release"
                  "SSL_CERT_FILE=${expectedCertificate}"
                  "TMPDIR=$runtime_tmp"
                )

                env "''${container_env[@]}" \
                  "$rootfs${expectedCommand}" eval \
                  'ClusterMurmur.Release.migrate!()'
                test "$(sqlite3 "$runtime_database" \
                  "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'stochastic_schedules'")" \
                  = "stochastic_schedules"

                smoke_output="$(env "''${container_env[@]}" \
                  timeout 30 \
                  "$rootfs${expectedEntrypoint}" -- \
                  "$rootfs${expectedCommand}" start_iex <<'EOF'
                IO.puts("CONTAINER_SMOKE=#{Application.spec(:cluster_murmur, :vsn)}:#{Node.alive?()}")
                {:ok, probe_socket} = :gen_tcp.connect({127, 0, 0, 1}, 45687, [:binary, active: false], 1000)
                :ok = :gen_tcp.send(probe_socket, "GET /startupz HTTP/1.1\r\n\r\n")
                {:ok, probe_response} = :gen_tcp.recv(probe_socket, 0, 1000)
                IO.puts("CONTAINER_STARTUP=#{String.starts_with?(probe_response, "HTTP/1.1 200 OK")}")
                System.stop(0)
                EOF
                )"
                grep -Fq "CONTAINER_SMOKE=${version}:false" <<< "$smoke_output"
                grep -Fq "CONTAINER_STARTUP=true" <<< "$smoke_output"
                touch "$out"
              '';
        }
      );

      formatter = forAllSystems (system: pkgsFor.${system}.nixfmt-tree);
    };
}
