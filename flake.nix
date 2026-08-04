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
          ./DESIGN.md
          ./LICENSE
          ./README.md
          ./SECURITY.md
          ./VERSION
          ./docs
          ./lib
          ./mix.exs
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

            packages = with pkgs; [
              actionlint
              beamPackages.elixir
              beamPackages.erlang
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
        in
        {
          application =
            pkgs.runCommand "cluster-murmur-application-check"
              {
                nativeBuildInputs = [
                  pkgs.beamPackages.elixir
                  pkgs.beamPackages.erlang
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
                mix format --check-formatted
                mix compile --warnings-as-errors
                mix test
                mix escript.build
                test "$(escript ./cluster-murmur --version)" = "$(tr -d '\n' < VERSION)"
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
