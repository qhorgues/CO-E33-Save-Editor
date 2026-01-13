{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-25.11";
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
          typescript
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

        # Construire le frontend avec mkDerivation et FOD
        # Plus simple et fonctionne avec n'importe quel lockfile
        frontend = pkgs.stdenv.mkDerivation {
          pname = "co-e33-save-editor-frontend";
          version = "2.0.1";

          src = ./.;

          nativeBuildInputs = with pkgs; [
            nodejs
            nodePackages.npm
            pnpm
            typescript
          ];

          buildPhase = ''
            export HOME=$TMPDIR
            export npm_config_cache=$TMPDIR/.npm

            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            export NODE_EXTRA_CA_CERTS=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            pnpm install --frozen-lockfile
            pnpm run build
          '';

          installPhase = ''
            mkdir -p $out
            cp -r dist $out/
          '';

          outputHashMode = "recursive";
          outputHashAlgo = "sha256";

          outputHash = "sha256-Ts/XBYxkgSPl0nmg0/1HnRiKzZHF3KavKQfvxksNtCQ=";

          meta = with pkgs.lib; {
            description = "CO-E33 Save Editor Frontend";
            platforms = platforms.linux;
          };
        };

        # Configuration Cargo pour Tauri
        src = ./src-tauri;

        # Arguments communs pour crane
        commonArgs = {
          inherit src;
          strictDeps = true;

          buildInputs = commonBuildInputs;
          nativeBuildInputs = commonNativeBuildInputs ++ [
            pkgs.cargo
            pkgs.rustc
            pkgs.makeWrapper
          ];

          dontStrip = true;
        };

        # Construire les dépendances Rust
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # Construire l'application Tauri
        tauri-app = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;

          preBuild = ''
            # Tauri s'attend à trouver le frontend dans ../dist
            mkdir -p ../dist
            cp -r ${frontend}/dist/* ../dist/

            # Créer le répertoire des permissions
            export PERMISSION_FILES_PATH=$PWD/permissions/schemas
            mkdir -p $PERMISSION_FILES_PATH

            # Copier les schémas de permissions
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

          doCheck = false;

          postInstall = ''
            source ${pkgs.makeWrapper}/nix-support/setup-hook

            # Créer la structure de dossiers
            tmpShare=$(mktemp -d)
            mkdir -p $tmpShare/co-e33-save-editor

            # Copier les ressources
            if [ -d ${./.}/permissions ]; then
              cp -r ${./.}/permissions $tmpShare/co-e33-save-editor/
            fi

            if [ -d ${frontend}/dist ]; then
              cp -rL ${frontend}/dist $tmpShare/co-e33-save-editor/
              chmod -R u+w $tmpShare/co-e33-save-editor/dist
            fi

            # Déplacer vers $out
            mkdir -p $out/share
            mv $tmpShare/co-e33-save-editor $out/share/

            # Wrapper pour les dépendances runtime
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

          meta = with pkgs.lib; {
            description = "CO-E33 Save Editor - Tauri Application";
            platforms = platforms.linux;
          };
        });

        launcher = pkgs.writeShellScriptBin "CO-E33_Save_Editor" ''
          #!${pkgs.bash}/bin/bash
          set -e

          # Lancer le frontend statique
          ${pkgs.nodePackages.http-server}/bin/http-server ${frontend}/dist -p 1420 &
          FRONT_PID=$!

          # Lancer l'app Tauri
          ${tauri-app}/bin/CO-E33_Save_Editor

              # Nettoyage
          kill $FRONT_PID || true
        '';
        
        apps = pkgs.symlinkJoin {
          name = "CO-E33 Save Editor";
          buildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            mkdir -p $out/share/applications
            cat > $out/share/applications/CO-E33_Save_Editor.desktop << EOF
            [Desktop Entry]
            Type=Application
            Name=Clair Obscur: Expedition 33 Save Editor
            Name[fr]=Clair Obscur: Expedition 33 Éditeur de sauvegarde
            Comment=Éditeur de sauvegarde pour le jeu Clair Obscur: Expedition 33
            Exec=${launcher}/bin/CO-E33_Save_Editor
            Icon=${frontend}/dist/iconsidebar/btnHome.png
            Terminal=false
            Categories=Games
            EOF
          '';
        };

      in {
        packages.default = apps;
      });
}
