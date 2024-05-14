# Credit: https://github.com/thefossguy/nix-kernel-dev
# Credit: https://github.com/fxttr/kernel

# TODO(Krey)
# * [ ] Declare the linux kernel as a package so that we can dodge compilation
# * [ ] Integrate DistCC/sc-cache to speed up compilation?
# * [ ] Integrate management to test the kernel in a VM
# * [ ] Integrate management to deploy the kernel on tsvetan without having to compile it
# * [ ] Integrate CI/CD to build the kernel and check it and upload the result into cachnix
# * [ ] Adjust .github/README
# * [ ] Migrate on self-hosted gitea

{
  description = "Kreyren's Linux Kernel";

  inputs = {
    # Release inputs
    nixpkgs-legacy.url = "github:nixos/nixpkgs/nixos-23.05";
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/*.tar.gz"; # a better way of using the latest stable version of nixpkgs without specifying specific release
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-master.url = "github:nixos/nixpkgs/master";
    nixpkgs-staging.url = "github:nixos/nixpkgs/staging";
    nixpkgs-staging-next.url = "github:nixos/nixpkgs/staging-next";

    # Principle inputs
    flake-parts.url = "github:hercules-ci/flake-parts";
    mission-control.url = "github:Platonic-Systems/mission-control";
    flake-root.url = "github:srid/flake-root";

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ { self, ... }:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        # ./somewhere..

        inputs.flake-root.flakeModule
        inputs.mission-control.flakeModule
      ];

      systems = [ "x86_64-linux" "aarch64-linux" "riscv64-linux" ];

      perSystem = { system, config, pkgs, llvmPkgs, ... }: let
        llvmPkgs = pkgs.llvmPackages;
        llvmVersion = builtins.elemAt (builtins.splitVersion llvmPkgs.clang.version) 0; # This gets the "major version" of LLVM, eg "16" or "17"

        commonInputs = [
          inputs.nixpkgs.legacyPackages.${system}.bashInteractive # For interactive terminal
          inputs.nixpkgs.legacyPackages.${system}.git # Working with the codebase
          inputs.nixpkgs.legacyPackages.${system}.fira-code # For liquratures in code editors
          inputs.nixpkgs.legacyPackages.${system}.rocmPackages.llvm.clang-tools-extra # IDE for C/C++ (glang,glang-tidy)
          inputs.nixpkgs.legacyPackages.${system}.gnumake
          inputs.nixpkgs.legacyPackages.${system}.bear # To generate compile_commands.json

          # Linters
          inputs.nixpkgs.legacyPackages.${system}.cppcheck
          inputs.nixpkgs.legacyPackages.${system}.flawfinder
          inputs.nixpkgs.legacyPackages.${system}.python310Packages.lizard

          # For `make menuconfig`
          inputs.nixpkgs.legacyPackages.${system}.pkg-config
          inputs.nixpkgs.legacyPackages.${system}.ncurses

          # testing the built kernel in a VM using QEMU
          inputs.nixpkgs.legacyPackages.${system}.debootstrap # fur creating ze rootfs
          inputs.nixpkgs.legacyPackages.${system}.gdb
          inputs.nixpkgs.legacyPackages.${system}.qemu_kvm

          # Nix
          inputs.nixpkgs.legacyPackages.${system}.nil # Needed for linting
          inputs.nixpkgs.legacyPackages.${system}.nixpkgs-fmt # Nixpkgs formatter
          inputs.nixos-generators.packages.${system}.nixos-generate # For generating NixOS systems

          # Kernel scripts
          inputs.nixpkgs.legacyPackages.${system}.python3 # For working with scripts

          # AI assist
          inputs.nixpkgs.legacyPackages.${system}.llm-ls # Dependency for llm-vscode

          # for a better kernel developer workflow
          # b4
          # dt-schema
          # neovim
          # yamllint

          # # extra utilities _I_ find useful
          # bat
          # broot
          # choose
          # fd
          # ripgrep
        ];

        commonShellHook = ''
          set -e # Exit on false return

          # Build the kernel if it's not already compiled
          [ -f ./vmlinux ] || {
            make defconfig
            bear -- make
          }

          # Get compile commands if they are not provided already
          [ -f ./compile_commands.json ] || python ./scripts/clang-tools/gen_compile_commands.py
        '';

        globalBuildFlags = {
          # build related flags (for the script)
          # CLEAN_BUILD = 0;
          # INSTALL_ZE_KERNEL = 1;
        };

        withLLVM = (pkgs.mkShell.override { stdenv = llvmPkgs.stdenv; }) {
          inputsFrom = [
            config.mission-control.devShell
            pkgs.linux_latest_with_llvm
          ];
          packages = commonInputs
            ++ [ pkgs.rustup ] # FIXME(Krey): Bad idea? Should maybe use oxalica's overlay? (rustup's leaving things in outside of repo?)
            # for some reason, `llvmPkgs.stdenv` does not have `lld` or actually `bintools`
            ++ [ llvmPkgs.bintools ];

          # Disable '-fno-strict-overflow' compiler flag because it causes the build to fail with the following error:
          # clang-16: error: argument unused during compilation: '-fno-strict-overflow' [-Werror,-Wunused-command-line-argument]
          hardeningDisable = [ "strictoverflow" ];

          env = rec {
            # just in case you want to disable building with the LLVM toolchain
            # **DO NOT SET THIS TO '0'**
            # **COMMENT IT OUT INSTEAD**
            # because, for some reason, setting `LLVM` to '0' still counts... :/
            LLVM = 1;
            # build related flags (for the script)
            BUILD_WITH_RUST = 1;

            # needed by Rust bindgen
            LIBCLANG_PATH = pkgs.lib.makeLibraryPath [ llvmPkgs.libclang.lib ];
            # because `grep gcc "$(nix-store -r $(command -v clang))/nix-support/libcxx-cxxflags"` matches
            # but `grep clang "$(nix-store -r $(command -v clang))/nix-support/libcxx-cxxflags"` **DOES NOT MATCH**
            KCFLAGS = "-isystem ${LIBCLANG_PATH}/clang/${llvmVersion}/include";
          } // globalBuildFlags;

          shellHook = commonShellHook;

          # **ONLY UNCOMMENT THIS IF YOU ARE _NOT_ USING HOME-MANAGER AND GET LOCALE ERRORS/WARNINGS**
          # If you are using home-manager, then add the following to your ~/.bashrc
          # `source $HOME/.nix-profile/etc/profile.d/hm-session-vars.sh`
          #LOCALE_ARCHIVE_2_27 = "${pkgs.glibcLocales}/lib/locale/locale-archive";
        };

        withGNU = pkgs.mkShell {
          inputsFrom = [
            config.mission-control.devShell
            pkgs.linux_latest
          ];
          packages = commonInputs;

          env = {
            # build related flags (for the script)
            BUILD_WITH_RUST = 0;
          } // globalBuildFlags;

          shellHook = commonShellHook;
        };
      in {
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;

          overlays = [
            (final: prev: {
              linux_latest_with_llvm = prev.linux_latest.override {
                stdenv = llvmPkgs.stdenv;
              };
            })
          ];
        };

        mission-control.scripts = {
          # Editorsdefinitions
          vscodium = {
            description = "VSCodium";
            category = "Integrated Editors";
            exec = "${inputs.nixpkgs-unstable.legacyPackages.${system}.vscodium}/bin/codium ./default.code-workspace";
          };
        };

        # FIXME-QA(Krey): The stdenv override should only be applied to LLVM builds
        devShells = (pkgs.mkShell.override { stdenv = llvmPkgs.stdenv; }) {
          default = withLLVM;
          withLLVM = withLLVM;
          withGNU = withGNU;
        };

        formatter = inputs.nixpkgs.legacyPackages.${system}.nixpkgs-fmt;
      };
    };
}
