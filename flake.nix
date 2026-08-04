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
          ./test
        ];
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

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor.${system};
          mixDeps = pkgs.beamPackages.fetchMixDeps {
            pname = "cluster-murmur-test-deps";
            version = pkgs.lib.strings.removeSuffix "\n" (builtins.readFile ./VERSION);
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

                export MIX_ENV=prod
                mix release --overwrite
                release_bin="$MIX_BUILD_PATH/rel/cluster_murmur/bin/cluster_murmur"
                migration_root="$TMPDIR/migration-success"
                migration_database="$migration_root/cluster-murmur.sqlite3"
                mkdir -p "$migration_root"
                chmod 0700 "$migration_root"
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
