{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    crane.url = "github:ipetkov/crane";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, crane, flake-utils }:
    flake-utils.lib.eachSystem [
      "x86_64-linux"
      "aarch64-linux"
      "i686-linux"
    ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        craneLib = crane.mkLib pkgs;

        # Dépendances communes
        commonBuildInputs = with pkgs; [
          glib
          gtk3
          libsoup_3
          webkitgtk_4_1
          librsvg
        ];

        commonNativeBuildInputs = with pkgs; [
          pkg-config
          wrapGAppsHook3
          makeWrapper
        ];

        runtimeDeps = with pkgs; [
          glib
          gtk3
          webkitgtk_4_1
          libsoup_3
          xdg-utils
        ];

        # Construire d'abord le frontend
        frontend = pkgs.stdenv.mkDerivation {
          pname = "co-e33-save-editor-frontend";
          version = "1.9.3";
          src = ./.;

          nativeBuildInputs = with pkgs; [
            bun
            nodejs
          ];

          buildPhase = ''
            export HOME=$TMPDIR
            bun install --frozen-lockfile

            # Builder le frontend avec les binaires directs
            ${pkgs.nodejs}/bin/node node_modules/typescript/lib/tsc.js || true
            ${pkgs.nodejs}/bin/node node_modules/vite/bin/vite.js build
          '';

          installPhase = ''
            mkdir -p $out
            cp -r dist $out/
          '';
        };

        # Configuration Cargo pour Tauri
        # Inclure tous les fichiers nécessaires (pas juste les sources Rust)
        src = pkgs.lib.cleanSourceWith {
          src = ./src-tauri;
          filter = path: type:
            # Inclure les fichiers Cargo par défaut
            (craneLib.filterCargoSources path type)
            # Ajouter les fichiers de config Tauri
            || (builtins.match ".*tauri\.conf\.json$" path != null)
            || (builtins.match ".*/capabilities/.*\.json$" path != null)
            || (builtins.match ".*/icons/.*" path != null);
        };

        # Arguments communs pour crane
        commonArgs = {
          inherit src;
          strictDeps = true;

          buildInputs = commonBuildInputs;
          nativeBuildInputs = commonNativeBuildInputs ++ [
            pkgs.cargo
            pkgs.rustc
            pkgs.makeWrapper  # Nécessaire pour wrapProgram
          ];

          # Désactiver le stripping automatique qui cause des problèmes
          dontStrip = true;
        };

        # Construire les dépendances Rust (sera caché)
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # Construire l'application Tauri
        tauri-app = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;

          # Copier le frontend buildé dans le bon endroit
          preBuild = ''
            # Tauri s'attend à trouver le frontend dans ../dist
            mkdir -p ../dist
            cp -r ${frontend}/dist/* ../dist/

            # Créer le répertoire des permissions dans un endroit accessible en écriture
            export PERMISSION_FILES_PATH=$PWD/permissions/schemas
            mkdir -p $PERMISSION_FILES_PATH

            # Copier les schémas de permissions s'ils existent depuis la racine du projet
            if [ -d ${./.}/permissions/schemas ]; then
              cp -r ${./.}/permissions/schemas/* $PERMISSION_FILES_PATH/ || true
            fi

            # Vérifier que tauri.conf.json existe
            if [ ! -f tauri.conf.json ]; then
              echo "ERROR: tauri.conf.json not found!"
              ls -la
              exit 1
            fi
          '';

          # Désactiver les tests pour accélérer le build
          doCheck = false;

          postInstall = ''
            # Le binaire est déjà dans $out/bin grâce à crane

            # Importer les fonctions de wrapGAppsHook
            source ${pkgs.makeWrapper}/nix-support/setup-hook

            # Créer la structure de dossiers pour les ressources dans un répertoire temporaire
            tmpShare=$(mktemp -d)
            mkdir -p $tmpShare/co-e33-save-editor

            # Copier les schémas de permissions si nécessaire au runtime
            if [ -d ${./.}/permissions ]; then
              cp -r ${./.}/permissions $tmpShare/co-e33-save-editor/
            fi

            # Copier le frontend (en préservant les permissions)
            if [ -d ${frontend}/dist ]; then
              cp -rL ${frontend}/dist $tmpShare/co-e33-save-editor/
              chmod -R u+w $tmpShare/co-e33-save-editor/dist
            fi

            # Maintenant déplacer vers $out
            mkdir -p $out/share
            mv $tmpShare/co-e33-save-editor $out/share/

            # Wrapper pour les dépendances runtime et les chemins
            for bin in $out/bin/*; do
              wrapProgram "$bin" \
                --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath runtimeDeps}" \
                --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.xdg-utils ]}" \
                --set PERMISSION_FILES_PATH "$out/share/co-e33-save-editor/permissions/schemas" \
                --set RUST_LOG "debug" \
                --set RUST_BACKTRACE "1" \
                --set WEBKIT_DISABLE_COMPOSITING_MODE "1" \
                --chdir "$out/share/co-e33-save-editor"
            done
          '';
        });

      in {
        packages = {
          default = tauri-app;
          frontend = frontend;
        };

        # Dev shell
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Frontend
            bun
            nodejs
            pnpm  # Ajout de pnpm

            # Rust
            cargo
            rustc
            rust-analyzer
            clippy
            rustfmt

            # Build tools
            pkg-config

            # Tauri dependencies
            glib
            gtk3
            libsoup_3
            webkitgtk_4_1
            librsvg

            # Utilitaires
            git

            xdg-utils
          ];

          buildInputs = commonBuildInputs;
          nativeBuildInputs = commonNativeBuildInputs;

          shellHook = ''
            # Configuration des chemins
            export PERMISSION_FILES_PATH=$PWD/permissions/schemas
            mkdir -p $PERMISSION_FILES_PATH

            # Variables pour Rust
            export RUST_BACKTRACE=1
            export RUST_LOG=info

            # Configuration pour WebKit
            export WEBKIT_DISABLE_COMPOSITING_MODE=1

            # Patcher tauri.conf.json pour utiliser bun au lieu de pnpm
            if [ -f src-tauri/tauri.conf.json ]; then
              if grep -q "pnpm run build" src-tauri/tauri.conf.json; then
                echo "⚠️  Détection de 'pnpm' dans tauri.conf.json"
                echo "   Considérez de le remplacer par 'bun run build'"
              fi
            fi

            # Bannière de bienvenue
            echo ""
            echo "🚀 Environnement de développement CO-E33 Save Editor"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "📦 Commandes disponibles:"
            echo "  bun install          - Installer les dépendances frontend"
            echo "  bun run tauri dev    - Lancer en mode développement"
            echo "  bun run tauri build  - Builder l'application"
            echo "  bun run build        - Builder uniquement le frontend"
            echo ""
            echo "🔧 Outils Rust:"
            echo "  cargo build          - Compiler le backend Rust"
            echo "  cargo check          - Vérifier le code"
            echo "  cargo clippy         - Linter Rust"
            echo "  cargo fmt            - Formater le code"
            echo ""
            echo "📝 Variables d'environnement:"
            echo "  PERMISSION_FILES_PATH = $PERMISSION_FILES_PATH"
            echo "  RUST_LOG = $RUST_LOG"
            echo ""
          '';
        };
      });
}
