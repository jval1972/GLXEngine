//
// The graphics engine GLXEngine. The unit of GXScene for Delphi
//
unit GXS.ROAMPatch;

(* Class for managing a ROAM (square) patch *)

interface

{$I Stage.Defines.inc}

uses
  System.SysUtils,

  Stage.OpenGL4, // GL_ARB_vertex_buffer_object
  Stage.VectorTypes,
  GXS.XOpenGL,
  Stage.VectorGeometry,
  GXS.VectorLists,
  Stage.Strings,
  GXS.HeightData,
  GXS.Isolines,
  GXS.Context;

type

  // Exception use by splitter for SafeTesselation
  EGLROAMException = class(Exception);

  PROAMTriangleNode = ^TgxROAMTriangleNode;
  TgxROAMTriangleNode = packed record
    Base, Left, Right: PROAMTriangleNode;
    LeftChild, RightChild: PROAMTriangleNode;
  end;

  TgxROAMRenderPoint = packed record
    X, Y: Integer;
    Idx: Integer;
  end;

  TgxROAMPatch = class(TObject)
  private
    FID: Integer;
    FHeightData: TgxHeightData; // Referred, not owned
    FHeightRaster: PSmallIntRaster;
    FTLNode, FBRNode: PROAMTriangleNode; 
    FTLVariance, FBRVariance: array of cardinal;
    FPatchSize, FTriangleCount: Integer;
    FListHandle: TgxListHandle;
    FTag: Integer;
    FObserverPosition: TAffineVector;
    FNorth, FSouth, FWest, FEast: TgxROAMPatch; // neighbours
    FHighRes: Boolean;
    FMaxDepth: Integer;
    FVertexScale, FVertexOffset: TAffineVector;
    FTextureScale, FTextureOffset: TAffineVector;
    FMaxTLVarianceDepth, FMaxBRVarianceDepth: Integer;
    FOcclusionQuery: TgxOcclusionQueryHandle;
    FOcclusionSkip, FOcclusionCounter: Integer;
    FLastOcclusionTestPassed: Boolean;
    FContourInterval: Integer;
    FContourWidth: Integer;
  protected
    procedure SetHeightData(Val: TgxHeightData);
    procedure SetOcclusionSkip(Val: Integer);
    procedure RenderROAM(Vertices: TgxAffineVectorList;
      VertexIndices: TgxIntegerList; TexCoords: TgxTexPointList);
    procedure RenderAsStrips(Vertices: TgxAffineVectorList;
      VertexIndices: TgxIntegerList; TexCoords: TgxTexPointList);
  public
    constructor Create;
    destructor Destroy; override;
    procedure ComputeVariance(Variance: Integer);
    procedure ResetTessellation;
    procedure ConnectToTheWest(WestPatch: TgxROAMPatch);
    procedure ConnectToTheNorth(NorthPatch: TgxROAMPatch);
    // Returns false if MaxCLODTriangles limit is reached(Lin)
    function Tesselate: Boolean;
    (*  AV free version of Tesselate.
      When IncreaseTrianglesCapacity is called, all PROAMTriangleNode
      values in higher function became invalid due to the memory shifting.
      Recursivity is the main problem, that's why SafeTesselate is calling
      Tesselate in a try..except. *)
    function SafeTesselate: Boolean;
    (*  Render the patch in high-resolution.
      The lists are assumed to have enough capacity to allow AddNC calls
      (additions without capacity check). High-resolution renders use
      display lists, and are assumed to be made together. *)
    procedure RenderHighRes(Vertices: TgxAffineVectorList;
      VertexIndices: TgxIntegerList; TexCoords: TgxTexPointList; ForceROAM: Boolean);
    (*  Render the patch by accumulating triangles.
      The lists are assumed to have enough capacity to allow AddNC calls
      (additions without capacity check).
      Once at least autoFlushVertexCount vertices have been accumulated,
      perform a FlushAccum *)
    procedure RenderAccum(Vertices: TgxAffineVectorList;
      VertexIndices: TgxIntegerList; TexCoords: TgxTexPointList;
      AutoFlushVertexCount: Integer);
    // Render all vertices accumulated in the arrays and set their count back to zero.
    class procedure FlushAccum(Vertices: TgxAffineVectorList;
      VertexIndices: TgxIntegerList; TexCoords: TgxTexPointList);
    property HeightData: TgxHeightData read FHeightData write SetHeightData;
    property VertexScale: TAffineVector read FVertexScale write FVertexScale;
    property VertexOffset: TAffineVector read FVertexOffset write FVertexOffset;
    property ObserverPosition: TAffineVector read FObserverPosition write FObserverPosition;
    property TextureScale: TAffineVector read FTextureScale write FTextureScale;
    property TextureOffset: TAffineVector read FTextureOffset write FTextureOffset;
    property HighRes: Boolean read FHighRes write FHighRes;
    // Number of frames to skip after an occlusion test returned zero pixels.
    property OcclusionSkip: Integer read FOcclusionSkip write SetOcclusionSkip;
    // Number of frames remaining to next occlusion test.
    property OcclusionCounter: Integer read FOcclusionCounter write FOcclusionCounter;
    (*  Result for the last occlusion test.
      Note that this value is updated upon rendering the tile in
      non-high-res mode only. *)
    property LastOcclusionTestPassed: Boolean read FLastOcclusionTestPassed;
    property ID: Integer read FID;
    property TriangleCount: Integer read FTriangleCount;
    property Tag: Integer read FTag write FTag;
    // Distance between contours - zero (default) for no contours
    property ContourInterval: Integer read FContourInterval write FContourInterval default 0;
    // Width of contours
    property ContourWidth: Integer read FContourWidth write FContourWidth default 1;
  end;

// Specifies the maximum number of ROAM triangles that may be allocated.
procedure SetROAMTrianglesCapacity(nb: Integer);
function GetROAMTrianglesCapacity: Integer;
// Draw contours on rendering terrain patches
procedure DrawContours(Vertices: TgxAffineVectorList; VertexIndices: TgxIntegerList;
  ContourInterval: Integer; ContourWidth: Integer; DecVal: Integer);

implementation // -----------------------------------------------------------

var
  FVBOVertHandle, FVBOTexHandle: TgxVBOArrayBufferHandle;
  FVBOIndicesHandle: TgxVBOElementArrayHandle;

  vNextPatchID: Integer;
  vNbTris, vTriangleNodesCapacity: Integer;
  vTriangleNodes: array of TgxROAMTriangleNode;

  RenderRaster: PSmallIntRaster;
  RenderIndices: PIntegerArray;
  RenderVertices: TgxAffineVectorList;
  RenderTexCoords: TgxTexPointList;

  TessMaxVariance: cardinal;
  TessMaxDepth: cardinal;
  TessCurrentVariance: PIntegerArray;
  TessObserverPosX, TessObserverPosY: Integer;

type
  TROAMVariancePoint = packed record
    X, Y, Z: Integer;
  end;

procedure SetROAMTrianglesCapacity(nb: Integer);
begin
  vNbTris := 0;
  if vTriangleNodesCapacity <> nb then
  begin
    SetLength(vTriangleNodes, nb);
    vTriangleNodesCapacity := nb;
  end;
end;

function GetROAMTrianglesCapacity: Integer;
begin
  Result := vTriangleNodesCapacity;
end;

procedure DrawContours(Vertices: TgxAffineVectorList; VertexIndices: TgxIntegerList;
  ContourInterval: Integer; ContourWidth: Integer; DecVal: Integer);
var
  i: Integer;
  Contours: TgxAffineVectorList;
  CurColor: TVector4f;

begin
  if ContourInterval > 0 then
  begin
    glPolygonOffset(1, 1);
    glEnable(GL_POLYGON_OFFSET_FILL);
    i := VertexIndices.Count - 3;
    Contours := TgxAffineVectorList.Create;
    while i >= 0 do
    begin
      TriangleElevationSegments(Vertices[VertexIndices[i]],
        Vertices[VertexIndices[i + 1]], Vertices[VertexIndices[i + 2]],
        ContourInterval, Contours);
      Dec(i, DecVal);
    end;
    glPushAttrib(GL_ENABLE_BIT or GL_CURRENT_BIT);
    glDisable(GL_TEXTURE_2D);
    glLineWidth(ContourWidth);
    glGetFloatv(GL_CURRENT_COLOR, @CurColor);
    glColor4f(0, 0, 0, 1);
    glBegin(GL_LINES);
     for i := 0 to Contours.Count - 1 do
       glVertex3fv(@Contours.List[i]);
    glEnd;
    glColor4fv(@CurColor);
    glPopAttrib;
    Contours.Free;
  end;
end;

// The result is the delta between the old address of the array and the new one
function IncreaseTrianglesCapacity(NewCapacity: Integer): int64;

  procedure FixNodePtr(var p: PROAMTriangleNode; const delta: int64);
  begin
    if p = nil then
      exit;
    Inc(PByte(p), delta);
  end;

var
  oldbase, newbase: pointer;
  node: PROAMTriangleNode;
  i, oldsize: Integer;
begin
  Result := 0;
  if NewCapacity <= vTriangleNodesCapacity then
    exit;

  oldsize := vTriangleNodesCapacity;

  oldbase := pointer(vTriangleNodes);
  SetLength(vTriangleNodes, NewCapacity);

  vTriangleNodesCapacity := NewCapacity;

  newbase := pointer(vTriangleNodes);

  // Array has not been relocated, no need to fix
  if oldbase = newbase then
    exit;

  // go through all the old nodes and fix the pointers
  // YP: Delphi needs int64 dual casting to avoid overflow exception
  Result := int64(Cardinal(newbase)) - int64(Cardinal(oldbase));
  for i := 0 to oldsize - 1 do
  begin
    node := @vTriangleNodes[i];

    FixNodePtr(node^.Base, Result);
    FixNodePtr(node^.Left, Result);
    FixNodePtr(node^.Right, Result);
    FixNodePtr(node^.LeftChild, Result);
    FixNodePtr(node^.RightChild, Result);
  end;
end;

function AllocTriangleNode: PROAMTriangleNode; 
var
  nilNode: PROAMTriangleNode;
begin
  if vNbTris >= vTriangleNodesCapacity then
  begin
    // grow by 50%
    IncreaseTrianglesCapacity(vTriangleNodesCapacity + (vTriangleNodesCapacity shr 1));
  end;
  Result := @vTriangleNodes[vNbTris]; ///Result := vNbTris;
  with Result^ do
  begin
    nilNode := nil;
    Left := nilNode;
    Right := nilNode;
    LeftChild := nilNode;
    RightChild := nilNode;
  end;
  Inc(vNbTris);
end;

function Split(tri: PROAMTriangleNode): Boolean;
var
  n: Integer;
  lc, rc: PROAMTriangleNode;
  Shift: int64;
begin
  Result := Assigned(tri.LeftChild);
  if Result then
    exit; // dont split if tri already has a left child
  with tri^ do
  begin
    // If this triangle is not in a proper diamond, force split our base neighbor
    if Assigned(Base) and (Base.Base <> tri) then
      Split(Base);

    n := vNbTris;
  end;

  if n >= vTriangleNodesCapacity - 1 then
  begin
    // grow by 50%
    Shift := IncreaseTrianglesCapacity(vTriangleNodesCapacity +
      (vTriangleNodesCapacity shr 1));
    if Shift <> 0 then
    begin
      raise EGLROAMException.Create
        ('PROAMTriangleNode addresses are invalid now');
    end;
  end;
  with tri^ do
  begin
    // Creates children and cross-link them
    lc := @vTriangleNodes[n]; // left child
    rc := @vTriangleNodes[n + 1]; // right child

    LeftChild := lc;
    RightChild := rc;

    rc.Base := Right; // right child
    rc.LeftChild := nil;
    rc.RightChild := LeftChild;
    rc.Right := LeftChild;

    lc.Base := Left; // left child
    lc.LeftChild := nil;
    lc.RightChild := LeftChild;
    lc.Left := RightChild;

    Inc(vNbTris, 2);

    // Link our Left Neighbor to the new children
    if Assigned(Left) then
      if Left.Base = tri then
        Left.Base := lc
      else if Left.Left = tri then
        Left.Left := lc
      else
        Left.Right := lc;
    // Link our Right Neighbor to the new children
    if Assigned(Right) then
      if Right.Base = tri then
        Right.Base := rc
      else if Right.Left = tri then
        Right.Left := rc
      else
        Right.Right := rc;
    // Link our Base Neighbor to the new children
    if Assigned(Base) then
    begin
      if Assigned(Base.LeftChild) then
      begin
        Base.LeftChild.Right := RightChild;
        RightChild.Left := Base.LeftChild;
        Base.RightChild.Left := LeftChild;
        LeftChild.Right := Base.RightChild;
      end
      else
        Split(Base);
    end
    else
    begin // An edge triangle, trivial case.
      LeftChild.Right := nil;
      RightChild.Left := nil;
    end;
  end;
  Result := True;
end;

// ------------------
// ------------------ TgxROAMPatch ------------------
// ------------------

constructor TgxROAMPatch.Create;
begin
  inherited Create;
  FID := vNextPatchID;
  Inc(vNextPatchID);
  FListHandle := TgxListHandle.Create;
  FContourInterval := 0;
  FOcclusionQuery := TgxOcclusionQueryHandle.Create;
end;

destructor TgxROAMPatch.Destroy;
begin
  FListHandle.Free;
  FOcclusionQuery.Free;
  inherited Destroy;
end;

procedure TgxROAMPatch.SetHeightData(Val: TgxHeightData);
begin
  FHeightData := Val;
  FPatchSize := FHeightData.Size - 1;
  FHeightRaster := Val.SmallIntRaster;
end;

procedure TgxROAMPatch.SetOcclusionSkip(Val: Integer);
begin
  if Val < 0 then
    Val := 0;
  if FOcclusionSkip <> Val then
  begin
    FOcclusionSkip := Val;
    FOcclusionQuery.DestroyHandle;
  end;
end;

procedure TgxROAMPatch.ConnectToTheWest(WestPatch: TgxROAMPatch);
begin
  if Assigned(WestPatch) then
  begin
    if not(WestPatch.HighRes or HighRes) then
    begin
       FTLNode.left := westPatch.FBRNode;
       westPatch.FBRNode.left := FTLNode;
    end;
    FWest := WestPatch;
    WestPatch.FEast := Self;
  end;
end;

procedure TgxROAMPatch.ConnectToTheNorth(NorthPatch: TgxROAMPatch);
begin
  if Assigned(NorthPatch) then
  begin
    if not(NorthPatch.HighRes or HighRes) then
    begin
      FTLNode.right := northPatch.FBRNode;
      northPatch.FBRNode.right := FTLNode;
    end;
    FNorth := NorthPatch;
    NorthPatch.FSouth := Self;
  end;
end;

procedure TgxROAMPatch.ComputeVariance(variance: Integer);
var
  raster: PSmallIntRaster;
  currentVariance: PIntegerArray;
  maxVarianceDepth: Integer;
  maxNonNullIndex: Integer;
  invVariance: Single;

  function ROAMVariancePoint(anX, anY: Integer): TROAMVariancePoint;
  begin
    Result.X := anX;
    Result.Y := anY;
    Result.Z := (Integer(FHeightRaster[anY][anX]) shl 8);
  end;

  function RecursComputeVariance(const Left, Right, apex: TROAMVariancePoint;
    node: Integer): cardinal;
  var
    half: TROAMVariancePoint;
    v: Cardinal;
    n2: Integer;
  begin
    with half do
    begin
      X := (Left.X + Right.X) shr 1;
      Y := (Left.Y + Right.Y) shr 1;
      Z := Integer(raster[Y][X]) shl 8;
      Result := ScaleAndRound(Abs(((Left.Z + Right.Z) div 2) - Z), invVariance);
    end;

    n2 := node shl 1;
    if n2 < maxVarianceDepth then
    begin
      v := RecursComputeVariance(apex, Left, half, n2);
      if v > Result then
        Result := v;
      v := RecursComputeVariance(Right, apex, half, 1 + n2);
      if v > Result then
        Result := v;
    end;
    currentVariance[node] := Result;
  end;

  procedure ScaleVariance(n, d: Integer);
  var
    newVal: Integer;
  begin
    if d >= 0 then
      newVal := (currentVariance[n] shl (d shr 1))
    else
      newVal := (currentVariance[n] shr (-d shr 1));
    currentVariance[n] := newVal;
    if newVal > 0 then
      if n > maxNonNullIndex then
        maxNonNullIndex := n;
    n := n shl 1;
    if n < maxVarianceDepth then
    begin
      Dec(d);
      ScaleVariance(n, d);
      ScaleVariance(n + 1, d);
    end;
  end;

var
  s, p: Integer;
begin
  invVariance := 1 / Variance;
  s := Sqr(FPatchSize);
  raster := FHeightRaster;
  FMaxDepth := 1;
  p := -1 - 8;
  repeat
    FMaxDepth := FMaxDepth shl 2;
    Inc(p);
  until FMaxDepth >= s;
  maxVarianceDepth := FMaxDepth;
  SetLength(FTLVariance, maxVarianceDepth);
  SetLength(FBRVariance, maxVarianceDepth);

  s := FPatchSize;
  currentVariance := @FTLVariance[0];
  maxNonNullIndex := 1;
  RecursComputeVariance(ROAMVariancePoint(0, s), ROAMVariancePoint(s, 0),
    ROAMVariancePoint(0, 0), 1);
  ScaleVariance(1, p);
  FMaxTLVarianceDepth := maxNonNullIndex + 1;
  SetLength(FTLVariance, FMaxTLVarianceDepth);
  currentVariance := @FBRVariance[0];
  maxNonNullIndex := 1;
  RecursComputeVariance(ROAMVariancePoint(s, 0), ROAMVariancePoint(0, s),
    ROAMVariancePoint(s, s), 1);
  ScaleVariance(1, p);
  FMaxBRVarianceDepth := maxNonNullIndex + 1;
  SetLength(FBRVariance, FMaxBRVarianceDepth);
end;

procedure TgxROAMPatch.ResetTessellation;
begin
  FTLNode := AllocTriangleNode;
  FBRNode := AllocTriangleNode;
  FTLNode.Base := FBRNode;
  FTLNode.Left := nil;
  FTLNode.Right := nil;
  FBRNode.Base := FTLNode;
  FBRNode.Left := nil;
  FBRNode.Right := nil;
  FNorth := nil;
  FSouth := nil;
  FWest := nil;
  FEast := nil;
end;

// returns false if tessellation failed due to MaxCLODTriangles limit
function RecursTessellate(tri: PROAMTriangleNode; n: Cardinal;
  const Left, Right, apex: Cardinal): Boolean;
var
  d: Integer;
begin
  Result := True;
  d := ((Left + Right) shr 1);
  if TessCurrentVariance[n] > d then
  begin
    Result := False;
    if Split(tri) then
    begin
      n := n shl 1;
      if n < TessMaxVariance then
      begin
        RecursTessellate(Tri.LeftChild, n, apex, Left, d);
        Result := RecursTessellate(Tri.RightChild, n + 1, Right, apex, d);
      end;
    end;
  end;
end;

function TgxROAMPatch.Tesselate: boolean;
var
  tessFrameVarianceDelta: Integer;

  function VertexDist(X, Y: Integer): cardinal;
  var
    f: Single;
  const
    c1Div100: Single = 0.01;
  begin
    if HighRes then
      f := 0.2 * Sqr(FPatchSize)
    else
      f := Sqr(X - TessObserverPosX) + Sqr(Y - TessObserverPosY) +
        tessFrameVarianceDelta;
    Result := Round(Sqrt(f) + f * c1Div100);
  end;

procedure FullBaseTess(tri: PROAMTriangleNode; n: cardinal); forward;

  procedure FullLeftTess(tri: PROAMTriangleNode; n: cardinal);
  begin
    if Split(tri) then
    begin
      n := n shl 1;
      if n < TessMaxDepth then
        FullBaseTess(tri.LeftChild, n);
    end;
  end;

  procedure FullRightTess(tri: PROAMTriangleNode; n: cardinal);
  begin
    if Split(tri) then
    begin
      n := n shl 1;
      if n < TessMaxDepth then
        FullBaseTess(tri.RightChild, n);
    end;
  end;

  procedure FullBaseTess(tri: PROAMTriangleNode; n: cardinal);
  begin
    if Split(tri) then
    begin
      n := n shl 1;
      if n < TessMaxDepth then
      begin
        FullRightTess(tri.LeftChild, n);
        FullLeftTess(tri.RightChild, n);
      end;
    end;
  end;

var
  s: Integer;
begin
  TessMaxDepth := FMaxDepth;
  TessObserverPosX := Round(FObserverPosition.X);
  TessObserverPosY := Round(FObserverPosition.Y);

  if HighRes then
  begin
    FullRightTess(FTLNode, 1);
    FullRightTess(FBRNode, 1);
    FullLeftTess(FBRNode, 1);
    FullLeftTess(FTLNode, 1);
    tessFrameVarianceDelta := 0;
  end
  else
  begin
    if Assigned(FNorth) and FNorth.HighRes then
      FullRightTess(FTLNode, 1);
    if Assigned(FSouth) and FSouth.HighRes then
      FullRightTess(FBRNode, 1);
    if Assigned(FEast) and FEast.HighRes then
      FullLeftTess(FBRNode, 1);
    if Assigned(FWest) and FWest.HighRes then
      FullLeftTess(FTLNode, 1);
    if FObserverPosition.Z > 0 then
      tessFrameVarianceDelta := Round(Sqr(FObserverPosition.Z * (1 / 16)))
    else
      tessFrameVarianceDelta := 0;
  end;
  s := FPatchSize;
  TessCurrentVariance := @FTLVariance[0];
  TessMaxVariance := FMaxTLVarianceDepth;
  Result := RecursTessellate(FTLNode, 1, VertexDist(0, s), VertexDist(s, 0), VertexDist(0, 0));
  TessCurrentVariance := @FBRVariance[0];
  TessMaxVariance := FMaxBRVarianceDepth;
  if Result then
    Result := RecursTessellate(FBRNode, 1, VertexDist(s, 0), VertexDist(0, s), VertexDist(s, s));
end;

function TgxROAMPatch.SafeTesselate: boolean;
var
  Fail: Boolean;
begin
  Result := False;
  Fail := True;
  repeat
    try
      Result := Tesselate;
      Fail := False;
    except
      on e: EGLROAMException do
      begin
        // Nothing to do, just wait the next iteration
        Fail := True;
      end;
    end;
  until not Fail;
end;

procedure TgxROAMPatch.RenderHighRes(vertices: TgxAffineVectorList;
  VertexIndices: TgxIntegerList; TexCoords: TgxTexPointList; ForceROAM: Boolean);

var
  Primitive: Cardinal;

begin
  // Prepare display list if needed
  if FListHandle.Handle = 0 then
  begin
    // either use brute-force strips or a high-res static tesselation
    if ForceROAM then
    begin
      ResetTessellation;
      SafeTesselate;
      RenderROAM(Vertices, VertexIndices, TexCoords);
      Primitive := GL_TRIANGLES;
      FTriangleCount := VertexIndices.Count div 3;
    end
    else
    begin
      RenderAsStrips(Vertices, VertexIndices, TexCoords);
      Primitive := GL_TRIANGLE_STRIP;
      FTriangleCount := VertexIndices.Count - 2 * FPatchSize;
    end;

    Vertices.Translate(VertexOffset);
    TexCoords.ScaleAndTranslate(PTexPoint(@TextureScale)^,
      PTexPoint(@TextureOffset)^);

    glVertexPointer(3, GL_FLOAT, 0, vertices.List);
    glTexCoordPointer(2, GL_FLOAT, 0, texCoords.List);

    FListHandle.AllocateHandle;
    glNewList(FListHandle.Handle, GL_COMPILE);
    glDrawElements(primitive, vertexIndices.Count, GL_UNSIGNED_INT, vertexIndices.List);
    glEndList;

    DrawContours(Vertices, VertexIndices, FContourInterval, FContourWidth, 1);

    Vertices.Count := 0;
    TexCoords.Count := 0;
    VertexIndices.Count := 0;
  end;

  // perform the render
  glCallList(FListHandle.Handle);
end;

procedure TgxROAMPatch.RenderAccum(vertices: TgxAffineVectorList;
  VertexIndices: TgxIntegerList; TexCoords: TgxTexPointList;
  AutoFlushVertexCount: Integer);
var
  OcclusionPassed: Boolean;
  n, nb, nvi: Integer;

begin
  // CLOD tiles are rendered via ROAM
  if (FOcclusionSkip > 0) and FOcclusionQuery.IsSupported then
  begin
    if FOcclusionQuery.Handle = 0 then
    begin
      FOcclusionQuery.AllocateHandle;
      FOcclusionCounter := -(ID mod (FOcclusionSkip));
    end;
    OcclusionPassed := (FOcclusionCounter <= 0) or (FOcclusionQuery.PixelCount > 0);
    Dec(FOcclusionCounter);
    if OcclusionPassed then
    begin
      if FOcclusionCounter <= 0 then
        Inc(FOcclusionCounter, FOcclusionSkip);
      FOcclusionQuery.BeginQuery;
    end;
  end
  else
    OcclusionPassed := True;
  FLastOcclusionTestPassed := OcclusionPassed;
  if OcclusionPassed then
  begin
    nvi := VertexIndices.Count;
    n := Vertices.Count;
    RenderROAM(Vertices, VertexIndices, TexCoords);
    nb := Vertices.Count - n;
    FTriangleCount := (VertexIndices.Count - nvi) div 3;
    Vertices.Translate(VertexOffset, n, nb);
    TexCoords.ScaleAndTranslate(PTexPoint(@TextureScale)^,
      PTexPoint(@TextureOffset)^, n, nb);
    DrawContours(Vertices, VertexIndices, FContourInterval, FContourWidth, 3);
    if FOcclusionQuery.Active then
    begin
      FlushAccum(Vertices, VertexIndices, TexCoords);
      FOcclusionQuery.EndQuery;
    end
    else if VertexIndices.Count > AutoFlushVertexCount then
      FlushAccum(Vertices, VertexIndices, TexCoords);
  end
  else
    FTriangleCount := 0;

end;

class procedure TgxROAMPatch.FlushAccum(vertices: TgxAffineVectorList;
  VertexIndices: TgxIntegerList; TexCoords: TgxTexPointList);
begin
  if VertexIndices.Count = 0 then
    Exit;

  if GL_ARB_vertex_buffer_object then
  begin
    FVBOVertHandle.AllocateHandle;
    FVBOVertHandle.BindBufferData(Vertices.List, Vertices.DataSize,
      GL_STREAM_DRAW_ARB);
    glVertexPointer(3, GL_FLOAT, 0, nil);

    FVBOTexHandle.AllocateHandle;
    FVBOTexHandle.BindBufferData(texCoords.List, texCoords.DataSize,
      GL_STREAM_DRAW_ARB);
    glTexCoordPointer(2, GL_FLOAT, 0, nil);

    glDrawRangeElements(GL_TRIANGLES, 0, vertices.Count - 1,
      vertexIndices.Count, GL_UNSIGNED_INT, vertexIndices.List);
    glBindBuffer(GL_ARRAY_BUFFER_ARB, 0);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER_ARB, 0);
  end
  else if GL_EXT_compiled_vertex_array and GL_EXT_draw_range_elements then
  begin
    glLockArraysEXT(0, vertices.Count);
    glDrawRangeElements(GL_TRIANGLES, 0, vertices.Count - 1,
      vertexIndices.Count, GL_UNSIGNED_INT, vertexIndices.List);
    glUnlockArraysEXT;
  end
  else
  begin
    glDrawElements(GL_TRIANGLES, vertexIndices.Count, GL_UNSIGNED_INT, vertexIndices.List);
  end;
  Vertices.Count := 0;
  TexCoords.Count := 0;
  VertexIndices.Count := 0;
end;

procedure RecursRender(const tri: PROAMTriangleNode;
  const Left, Right, apex: TgxROAMRenderPoint);
var
  half: TgxROAMRenderPoint;
  LocalIndices: PIntegerArray;
begin
  if Assigned(tri.LeftChild) then
  begin // = if node is split
    half.X := (Left.X + Right.X) shr 1;
    half.Y := (Left.Y + Right.Y) shr 1;

    RenderTexCoords.AddNC(@half.X);
    half.Idx := RenderVertices.AddNC(@half.X, RenderRaster[half.Y][half.X]);
    RecursRender(tri.LeftChild, apex, Left, half);
    RecursRender(tri.RightChild, Right, apex, half);
  end
  else
  begin
    LocalIndices := RenderIndices;
    LocalIndices[0] := Left.Idx;
    LocalIndices[1] := apex.Idx;
    LocalIndices[2] := Right.Idx;
    RenderIndices := PIntegerArray(@LocalIndices[3]);
  end;
end;

procedure TgxROAMPatch.RenderROAM(Vertices: TgxAffineVectorList;
  VertexIndices: TgxIntegerList; TexCoords: TgxTexPointList);

  procedure ROAMRenderPoint(var p: TgxROAMRenderPoint; anX, anY: Integer);
  begin
    p.X := anX;
    p.Y := anY;
    p.Idx := Vertices.Add(anX, anY, RenderRaster[anY][anX]);
    TexCoords.Add(anX, anY);
  end;

var
  rtl, rtr, rbl, rbr: TgxROAMRenderPoint;
begin
  RenderVertices := Vertices;
  RenderTexCoords := TexCoords;
  VertexIndices.AdjustCapacityToAtLeast(Sqr(FPatchSize) * 6 + 15000);
  // this is required, the actual item count is maintained out of the list scope
  VertexIndices.SetCountResetsMemory := False;
  RenderIndices := @VertexIndices.List[VertexIndices.Count];

  RenderRaster := FHeightData.SmallIntRaster;

  ROAMRenderPoint(rtl, 0, 0);
  ROAMRenderPoint(rtr, FPatchSize, 0);
  ROAMRenderPoint(rbl, 0, FPatchSize);
  ROAMRenderPoint(rbr, FPatchSize, FPatchSize);

  RecursRender(FTLNode, rbl, rtr, rtl);
  RecursRender(FBRNode, rtr, rbl, rbr);

  VertexIndices.Count := (Cardinal(RenderIndices) - Cardinal(VertexIndices.List)) div SizeOf(Integer);
end;

procedure TgxROAMPatch.RenderAsStrips(vertices: TgxAffineVectorList;
  VertexIndices: TgxIntegerList; TexCoords: TgxTexPointList);

var
  X, Y, baseTop, rowLength: Integer;
  p: TAffineVector;
  Row: PSmallIntArray;
  raster: PSmallIntRaster;
  Tex: TTexPoint;
  VerticesList: PAffineVector;
  TexCoordsList: PTexPoint;
  IndicesList: PInteger;
begin
  raster := FHeightData.SmallIntRaster;
  rowLength := FPatchSize + 1;
  // prepare vertex data
  Vertices.Count := Sqr(rowLength);
  VerticesList := PAffineVector(Vertices.List);
  TexCoords.Count := Sqr(rowLength);
  TexCoordsList := PTexPoint(TexCoords.List);
  for Y := 0 to FPatchSize do
  begin
    p.Y := Y;
    Tex.T := p.Y;
    Row := raster[Y];
    for X := 0 to FPatchSize do
    begin
      p.X := X;
      Tex.s := p.X;
      p.Z := Row[X];
      VerticesList^ := p;
      Inc(VerticesList);
      TexCoordsList^ := Tex;
      Inc(TexCoordsList);
    end;
  end;
  // build indices list
  baseTop := 0;
  VertexIndices.Count := (rowLength * 2 + 2) * FPatchSize - 1;
  IndicesList := PInteger(VertexIndices.List);
  Y := 0;
  while Y < FPatchSize do
  begin
    if Y > 0 then
    begin
      IndicesList^ := baseTop + FPatchSize;
      Inc(IndicesList);
    end;
    for X := baseTop + FPatchSize downto baseTop do
    begin
      IndicesList^ := X;
      PIntegerArray(IndicesList)[1] := rowLength + X;
      Inc(IndicesList, 2);
    end;
    IndicesList^ := baseTop + rowLength;
    Inc(baseTop, rowLength);
    PIntegerArray(IndicesList)[1] := baseTop + rowLength;
    Inc(IndicesList, 2);
    for X := baseTop to baseTop + FPatchSize do
    begin
      IndicesList^ := rowLength + X;
      PIntegerArray(IndicesList)[1] := X;
      Inc(IndicesList, 2);
    end;
    IndicesList^ := baseTop + FPatchSize;
    Inc(IndicesList);
    Inc(baseTop, rowLength);
    Inc(Y, 2);
  end;
  VertexIndices.Count := VertexIndices.Count - 1;
end;

// ------------------------------------------------------------------
initialization
// ------------------------------------------------------------------

FVBOVertHandle := TgxVBOArrayBufferHandle.Create;
FVBOTexHandle := TgxVBOArrayBufferHandle.Create;
FVBOIndicesHandle := TgxVBOElementArrayHandle.Create;

finalization //-------------------------------------------------------------

FVBOVertHandle.Free;
FVBOTexHandle.Free;
FVBOIndicesHandle.Free;

SetROAMTrianglesCapacity(0);

// -------------------------------------------------------------------------

end.
