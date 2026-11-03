{
  description = "p0ng portable Swift test environment (candidate; not yet CI-qualified)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/3083577807ab374ec345b338b319349da443e68d";

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      swiftToolchain = pkgs.swift;
      expectedSwiftVersion = "6.2.4";
    in
    assert pkgs.lib.getVersion swiftToolchain == expectedSwiftVersion;
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          swiftToolchain
          pkgs.swiftpm
          pkgs.git
          pkgs.pkg-config
        ];
      };
    };
}
