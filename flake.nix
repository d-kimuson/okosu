{
  description = "okosu development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
            }
          )
        );
    in
    {
      # ランタイムが使う whisper-stream の pin 留め済み提供元。
      # アプリ(Finder 起動)は nix develop の PATH を見ないため、実体は profile に
      # 入れる: `nix profile install ~/repos/okosu#whisper-cpp`
      # (参照先は flake.lock 固定。imperative な nixpkgs# 指定は使わないこと)
      packages = forAllSystems (pkgs: {
        whisper-cpp = pkgs.whisper-cpp;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.xcodegen
            pkgs.swiftlint
          ];

          shellHook = ''
            # Xcode は Apple 製で nix 管理外。親シェル(pi 実行環境)の nix 変数が
            # 残っているとビルドが壊れる: SDKROOT(Apple SDK すり替え)→stdlib解決失敗、
            # LD=ld(PATH から nix の ld を引く)→リンク失敗。実ビルドは system Xcode。
            # nix が提供するのは xcodegen / swiftlint のみ。
            unset SDKROOT LD
            export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
            echo "okosu dev shell"
            echo "  xcodegen  $(xcodegen --version)"
            echo "  swiftlint $(swiftlint version)"
            echo "  xcodebuild:"
            xcodebuild -version 2>/dev/null | sed 's/^/    /' || echo "    (Xcode not found: install Xcode from the App Store)"
          '';
        };
      });
    };
}
