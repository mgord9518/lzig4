{ stdenv, pkgs }: stdenv.mkDerivation rec {
  pname = "lzig4";
  version = "0.0.15";

  src = ../.;

  nativeBuildInputs = with pkgs; [
    zig_0_15.hook
  ];

  phases = [ "unpackPhase" "buildPhase" "installPhase" ];
}
