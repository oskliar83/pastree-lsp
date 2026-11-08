unit DemoExpected;

{ Fixture for LspClientSmoke 5b-ter: on the right side of a comparison the
  values of the left side's type rank first, and no procedure is listed.
  Since 0.85.0, inside the values that convert the nearer conversion first:
  for a Double a Single before a Byte. }

interface

type
  TExpColor = (ecRed, ecGreen);
  TExpShape = (esRound, esSquare);

procedure ExpReset;
procedure ExpRun;

implementation

procedure ExpReset;
begin
end;

procedure ExpRun;
var
  LColor: TExpColor;
  LShape: TExpShape;
  LStamp: Double;
  LSingle: Single;
  LByte: Byte;
begin
  LShape := esRound;
  LStamp := LSingle + LByte;
  if LColor = ecRed then
    ExpReset;
end;

end.
