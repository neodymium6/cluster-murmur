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
          ./.markdownlint.yaml
          ./.formatter.exs
          ./AGENTS.md
          ./config
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
            hash = "sha256-EKELmjAs8BwUzMq+ToC3SRpo7DI0cPUvHVIxfRtXMAE=";
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

      packages = forAllSystems (system: {
        default = releaseFor system;
        cluster-murmur = releaseFor system;
      });

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
            hash = "sha256-EKELmjAs8BwUzMq+ToC3SRpo7DI0cPUvHVIxfRtXMAE=";
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
                markdownlint-cli2 AGENTS.md DESIGN.md README.md SECURITY.md docs/**/*.md
                touch "$out"
              '';
        }
      );

      formatter = forAllSystems (system: pkgsFor.${system}.nixfmt-tree);
    };
}
