#include "HorizontalStepImporter.h"

#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <Bnd_Box.hxx>
#include <DESTEP_Parameters.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Interface_Static.hxx>
#include <NCollection_List.hxx>
#include <NCollection_Sequence.hxx>
#include <Poly.hxx>
#include <Poly_Triangulation.hxx>
#include <Precision.hxx>
#include <Quantity_Color.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <STEPCAFControl_Writer.hxx>
#include <Standard_Version.hxx>
#include <TDataStd_Name.hxx>
#include <TDF_Label.hxx>
#include <TDocStd_Document.hxx>
#include <TopLoc_Location.hxx>
#include <TopAbs_Orientation.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Builder.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Wire.hxx>
#include <TopoDS_Iterator.hxx>
#include <XCAFApp_Application.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <STEPControl_Reader.hxx>
#include <ShapeProcess.hxx>
#include <gp_Ax1.hxx>
#include <gp_Ax2.hxx>
#include <gp_Circ.hxx>
#include <gp_Dir.hxx>
#include <gp_Pln.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>
#include <gp_Vec.hxx>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace {

constexpr double userPrecision = 0.14;
constexpr double userAngle = 0.52359878;

struct MeshAccumulator {
    std::vector<HNStepVertex> vertices;
    std::vector<uint32_t> indices;
    Handle(XCAFDoc_ColorTool) colorTool;
    Handle(XCAFDoc_ShapeTool) shapeTool;
};

bool readSTEP(const char *path, Handle(TDocStd_Document) &document)
{
    STEPCAFControl_Reader reader;
    IFSelect_ReturnStatus status = reader.ReadFile(path);
    if (status != IFSelect_RetDone) {
        return false;
    }

    if (!Interface_Static::SetIVal("read.precision.mode", 1)) {
        return false;
    }
    if (!Interface_Static::SetRVal("read.precision.val", userPrecision)) {
        return false;
    }

    reader.SetColorMode(true);
    reader.SetNameMode(false);
    reader.SetLayerMode(false);

    if (!reader.Transfer(document)) {
        document->Close();
        return false;
    }

    return reader.NbRootsForTransfer() >= 1;
}

bool getColor(MeshAccumulator &accumulator, TDF_Label label, Quantity_Color &color)
{
    while (!label.IsNull()) {
        if (accumulator.colorTool->GetColor(label, XCAFDoc_ColorGen, color)
            || accumulator.colorTool->GetColor(label, XCAFDoc_ColorSurf, color)
            || accumulator.colorTool->GetColor(label, XCAFDoc_ColorCurv, color)) {
            return true;
        }

        label = label.Father();
    }

    return false;
}

Quantity_Color faceColor(
    MeshAccumulator &accumulator,
    const TopoDS_Face &face,
    const Quantity_Color *inheritedColor
) {
    Quantity_Color color;
    TDF_Label label;

    if (accumulator.colorTool->ShapeTool()->Search(face, label)) {
        if (accumulator.colorTool->GetColor(label, XCAFDoc_ColorGen, color)
            || accumulator.colorTool->GetColor(label, XCAFDoc_ColorCurv, color)
            || accumulator.colorTool->GetColor(label, XCAFDoc_ColorSurf, color)) {
            return color;
        }
    }

    if (inheritedColor != nullptr) {
        return *inheritedColor;
    }

    return Quantity_Color(0.5, 0.5, 0.5, Quantity_TOC_RGB);
}

gp_Trsf combinedTransform(const gp_Trsf &parentTransform, const TopLoc_Location &location)
{
    gp_Trsf transform = parentTransform;
    transform.Multiply(location.Transformation());
    return transform;
}

bool shapeCarriesPlacementLocation(const TopoDS_Shape &shape)
{
    switch (shape.ShapeType()) {
    case TopAbs_COMPOUND:
    case TopAbs_COMPSOLID:
    case TopAbs_SOLID:
        return true;
    default:
        return false;
    }
}

void appendFace(
    MeshAccumulator &accumulator,
    const TopoDS_Face &face,
    const Quantity_Color *inheritedColor,
    const gp_Trsf &parentTransform
) {
    if (face.IsNull()) {
        return;
    }

    TopLoc_Location location;
    Handle(Poly_Triangulation) triangulation = BRep_Tool::Triangulation(face, location);

    if (triangulation.IsNull() || triangulation->Deflection() > userPrecision + Precision::Confusion()) {
        BRepMesh_IncrementalMesh mesh(face, userPrecision, false, userAngle);
        triangulation = BRep_Tool::Triangulation(face, location);
    }

    if (triangulation.IsNull() || triangulation->NbNodes() <= 0 || triangulation->NbTriangles() <= 0) {
        return;
    }

    const Quantity_Color color = faceColor(accumulator, face, inheritedColor);
    const gp_Trsf transform = parentTransform;
    const uint32_t vertexBase = static_cast<uint32_t>(accumulator.vertices.size());
    accumulator.vertices.reserve(accumulator.vertices.size() + triangulation->NbNodes());

    Poly::ComputeNormals(triangulation);
    for (int nodeIndex = 1; nodeIndex <= triangulation->NbNodes(); nodeIndex++) {
        gp_Pnt point = triangulation->Node(nodeIndex);
        point.Transform(transform);

        gp_Dir normal = triangulation->Normal(nodeIndex);
        normal.Transform(transform);

        accumulator.vertices.push_back(HNStepVertex {
            static_cast<float>(point.X()),
            static_cast<float>(point.Y()),
            static_cast<float>(point.Z()),
            static_cast<float>(normal.X()),
            static_cast<float>(normal.Y()),
            static_cast<float>(normal.Z()),
            static_cast<float>(color.Red()),
            static_cast<float>(color.Green()),
            static_cast<float>(color.Blue())
        });
    }

    accumulator.indices.reserve(accumulator.indices.size() + triangulation->NbTriangles() * 3);
    for (int triangleIndex = 1; triangleIndex <= triangulation->NbTriangles(); triangleIndex++) {
        int a = 0;
        int b = 0;
        int c = 0;
        triangulation->Triangle(triangleIndex).Get(a, b, c);

        if (face.Orientation() == TopAbs_REVERSED) {
            std::swap(b, c);
        }

        accumulator.indices.push_back(vertexBase + static_cast<uint32_t>(a - 1));
        accumulator.indices.push_back(vertexBase + static_cast<uint32_t>(b - 1));
        accumulator.indices.push_back(vertexBase + static_cast<uint32_t>(c - 1));
    }
}

void processShell(
    MeshAccumulator &accumulator,
    const TopoDS_Shape &shape,
    const Quantity_Color *inheritedColor,
    const gp_Trsf &transform
) {
    for (TopoDS_Iterator iterator(shape, false, false); iterator.More(); iterator.Next()) {
        const TopoDS_Shape &subShape = iterator.Value();
        if (subShape.ShapeType() == TopAbs_FACE) {
            appendFace(accumulator, TopoDS::Face(subShape), inheritedColor, transform);
        }
    }
}

void processShape(MeshAccumulator &accumulator, const TopoDS_Shape &shape, const gp_Trsf &parentTransform)
{
    if (shape.IsNull()) {
        return;
    }

    const gp_Trsf transform = shapeCarriesPlacementLocation(shape)
        ? combinedTransform(parentTransform, shape.Location())
        : parentTransform;
    Quantity_Color color;
    Quantity_Color *inheritedColor = nullptr;

    TDF_Label label = accumulator.shapeTool->FindShape(shape, false);
    if (!label.IsNull() && getColor(accumulator, label, color)) {
        inheritedColor = &color;
    }

    switch (shape.ShapeType()) {
    case TopAbs_COMPOUND:
    case TopAbs_COMPSOLID:
    case TopAbs_SOLID:
        for (TopoDS_Iterator iterator(shape, false, false); iterator.More(); iterator.Next()) {
            processShape(accumulator, iterator.Value(), transform);
        }
        break;
    case TopAbs_SHELL:
        processShell(accumulator, shape, inheritedColor, transform);
        break;
    case TopAbs_FACE:
        appendFace(accumulator, TopoDS::Face(shape), inheritedColor, transform);
        break;
    default:
        break;
    }
}

TopoDS_Shape faceFromOutline(const HNStepPoint *outline, uint32_t outlineCount)
{
    BRepBuilderAPI_MakeWire wire;
    for (uint32_t index = 0; index < outlineCount; index++) {
        const HNStepPoint &p0 = outline[index];
        const HNStepPoint &p1 = outline[(index + 1) % outlineCount];
        if (p0.x == p1.x && p0.y == p1.y) {
            continue;
        }
        wire.Add(BRepBuilderAPI_MakeEdge(gp_Pnt(p0.x, p0.y, 0.0), gp_Pnt(p1.x, p1.y, 0.0)));
    }
    return BRepBuilderAPI_MakeFace(wire);
}

TopoDS_Shape faceFromHole(const HNStepHole &hole)
{
    const gp_Ax2 axis(gp_Pnt(hole.x, hole.y, 0.0), gp_Dir(0.0, 0.0, 1.0));
    const gp_Circ circle(axis, hole.diameter / 2.0);
    BRepBuilderAPI_MakeWire wire;
    wire.Add(BRepBuilderAPI_MakeEdge(circle));
    return BRepBuilderAPI_MakeFace(wire);
}

} // namespace

bool HNStepImport(const char *path, HNStepMesh *mesh)
{
    if (path == nullptr || mesh == nullptr) {
        return false;
    }

    HNStepMeshFree(mesh);

    Handle(XCAFApp_Application) application = XCAFApp_Application::GetApplication();
    Handle(TDocStd_Document) document;
    application->NewDocument("MDTV-XCAF", document);

    if (!readSTEP(path, document)) {
        return false;
    }

    MeshAccumulator accumulator;
    accumulator.shapeTool = XCAFDoc_DocumentTool::ShapeTool(document->Main());
    accumulator.colorTool = XCAFDoc_DocumentTool::ColorTool(document->Main());

    NCollection_Sequence<TDF_Label> freeShapes;
    accumulator.shapeTool->GetFreeShapes(freeShapes);

    gp_Trsf identity;
    for (int shapeIndex = 1; shapeIndex <= freeShapes.Length(); shapeIndex++) {
        TopoDS_Shape shape = accumulator.shapeTool->GetShape(freeShapes.Value(shapeIndex));
        processShape(accumulator, shape, identity);
    }

    document->Close();

    if (accumulator.vertices.empty() || accumulator.indices.empty()) {
        return false;
    }

    mesh->vertexCount = static_cast<uint32_t>(accumulator.vertices.size());
    mesh->indexCount = static_cast<uint32_t>(accumulator.indices.size());
    mesh->vertices = static_cast<HNStepVertex *>(std::malloc(sizeof(HNStepVertex) * mesh->vertexCount));
    mesh->indices = static_cast<uint32_t *>(std::malloc(sizeof(uint32_t) * mesh->indexCount));

    if (mesh->vertices == nullptr || mesh->indices == nullptr) {
        HNStepMeshFree(mesh);
        return false;
    }

    std::memcpy(mesh->vertices, accumulator.vertices.data(), sizeof(HNStepVertex) * mesh->vertexCount);
    std::memcpy(mesh->indices, accumulator.indices.data(), sizeof(uint32_t) * mesh->indexCount);
    return true;
}

void HNStepMeshFree(HNStepMesh *mesh)
{
    if (mesh == nullptr) {
        return;
    }

    std::free(mesh->vertices);
    std::free(mesh->indices);
    mesh->vertices = nullptr;
    mesh->indices = nullptr;
    mesh->vertexCount = 0;
    mesh->indexCount = 0;
}

// Where a component's 3D model sits on the board, as a single rigid transform.
// All inputs are millimetres / radians.
//
// Specification — the placement is the product, applied right to left:
//
//   translate(position)
//     · rotateZ(placement angle, plus a half turn on the bottom side)
//     · flipX(half turn)                      [bottom side only]
//     · translate(model offset, with z raised as below)
//     · rotateX(-roll) · rotateY(-pitch) · rotateZ(-yaw)
//
//   z gains a small clearance so the model does not co-plane with the copper and
//   z-fight it, and — on the top side only — the board thickness, because top
//   parts stand on the far face of the substrate. A bottom part is turned over,
//   and that half turn about X negates the offset, so its clearance carries it
//   BELOW z = 0 onto the underside rather than above it.
//
// The composition is dictated by the geometry: a part must end up at its
// placement, the right way up for its side, with the model's own orientation
// applied about the model's own origin.
static TopLoc_Location modelLocation(
    bool bottom,
    double posX,
    double posY,
    double rotation,
    double offsetX,
    double offsetY,
    double offsetZ,
    double roll,
    double pitch,
    double yaw,
    double boardThickness
) {
    // Keeps the model clear of the board surface it sits on.
    constexpr double surfaceClearance = 0.05;

    const gp_Pnt origin(0.0, 0.0, 0.0);
    const gp_Dir xAxis(1.0, 0.0, 0.0);
    const gp_Dir yAxis(0.0, 1.0, 0.0);
    const gp_Dir zAxis(0.0, 0.0, 1.0);

    auto translation = [](double x, double y, double z) {
        gp_Trsf t;
        t.SetTranslation(gp_Vec(x, y, z));
        return t;
    };
    auto rotation_about = [&origin](const gp_Dir &axis, double radians) {
        gp_Trsf t;
        t.SetRotation(gp_Ax1(origin, axis), radians);
        return t;
    };

    // Top parts stand on the far face of the substrate; bottom parts hang from
    // z = 0 and are turned over, so only the top side clears the thickness.
    const double liftZ = offsetZ + surfaceClearance + (bottom ? 0.0 : boardThickness);

    gp_Trsf placement = translation(posX, posY, 0.0);
    placement.Multiply(rotation_about(zAxis, bottom ? rotation + M_PI : rotation));
    if (bottom) {
        placement.Multiply(rotation_about(xAxis, M_PI));
    }
    placement.Multiply(translation(offsetX, offsetY, liftZ));

    // The model's own orientation, about the model origin, after it has been
    // moved into place.
    placement.Multiply(rotation_about(xAxis, -roll));
    placement.Multiply(rotation_about(yAxis, -pitch));
    placement.Multiply(rotation_about(zAxis, -yaw));

    return TopLoc_Location(placement);
}

// Exposes the component placement as a row-major 3x4 matrix so the transform
// can be pinned by tests without loading a STEP file. See
// StepModelPlacementGoldenData.
extern "C" void HNStepModelPlacement(
    bool bottom, double posX, double posY, double rotation,
    double offsetX, double offsetY, double offsetZ,
    double roll, double pitch, double yaw, double boardThickness,
    double *outMatrix
) {
    auto fill = [](const TopLoc_Location &loc, double *out) {
        const gp_Trsf &t = loc.Transformation();
        for (int row = 1; row <= 3; ++row) {
            for (int col = 1; col <= 4; ++col) {
                out[(row - 1) * 4 + (col - 1)] = t.Value(row, col);
            }
        }
    };
    fill(modelLocation(bottom, posX, posY, rotation, offsetX, offsetY, offsetZ,
                       roll, pitch, yaw, boardThickness), outMatrix);
}

// Loads a model STEP file as a single shape (no per-source colors — geometry
// only). Returns a null shape on failure.
static TopoDS_Shape loadModelShape(const char *path)
{
    if (path == nullptr || std::strlen(path) == 0) {
        return TopoDS_Shape();
    }
    STEPControl_Reader reader;
    if (reader.ReadFile(path) != IFSelect_RetDone) {
        return TopoDS_Shape();
    }
    reader.TransferRoots();
    return reader.OneShape();
}

// A model's size: the longest side of its bounding box, as its file draws
// it, so a part turned on the board is the size it was. The box takes in the
// shape's tolerances and a spline's control points, so it is never smaller
// than the model: a model left out for being smaller than a size in every
// dimension is.
static double modelSize(const TopoDS_Shape &shape)
{
    Bnd_Box box;
    BRepBndLib::Add(shape, box, false);
    if (box.IsVoid()) {
        return 0.0;
    }
    double xMin = 0.0, yMin = 0.0, zMin = 0.0, xMax = 0.0, yMax = 0.0, zMax = 0.0;
    box.Get(xMin, yMin, zMin, xMax, yMax, zMax);
    return std::max({xMax - xMin, yMax - yMin, zMax - zMin});
}

// Twice a path's signed area: positive counterclockwise.
static double signedArea(const HNStepPoint *points, uint32_t count)
{
    double area = 0.0;
    for (uint32_t index = 0; index < count; index++) {
        const HNStepPoint &p0 = points[index];
        const HNStepPoint &p1 = points[(index + 1) % count];
        area += p0.x * p1.y - p1.x * p0.y;
    }
    return area;
}

// How far a copper path's points may stray from the arc or line that takes
// their place, in millimetres.
constexpr double pathTolerance = 0.001;
// How far an arc may stand off the chords it takes the place of, in
// millimetres: less than the export shrinks its copper by, so where shrinking
// opened a gap between two paths, their arcs bulging into it cannot meet.
constexpr double arcMaximumSagitta = 0.0025;
// The turn, in radians, at a point of a polygon standing for an arc: more
// than none, and less than a 12-gon's, so a polygon drawn as one stays one.
constexpr double arcMinimumTurn = 1.0e-4;
constexpr double arcMaximumTurn = 0.45;

// The circle through three points, false when they are in a line.
static bool circleThrough(const HNStepPoint &a, const HNStepPoint &b, const HNStepPoint &c,
                          double &centerX, double &centerY, double &radius)
{
    // About a, so the squares stay small.
    const double bx = b.x - a.x, by = b.y - a.y;
    const double cx = c.x - a.x, cy = c.y - a.y;
    const double d = 2.0 * (bx * cy - by * cx);
    if (std::fabs(d) < 1.0e-18) {
        return false;
    }
    const double b2 = bx * bx + by * by;
    const double c2 = cx * cx + cy * cy;
    const double ux = (cy * b2 - by * c2) / d;
    const double uy = (bx * c2 - cx * b2) / d;
    centerX = a.x + ux;
    centerY = a.y + uy;
    radius = std::hypot(ux, uy);
    return true;
}

// A closed path at height z, run counterclockwise or clockwise as asked, or a
// null wire when fewer than three of its points are apart. A polygon is how
// the copper reaches here, its arcs as runs of short chords: a run of points
// within pathTolerance of one circle, turning alike, is drawn as that arc,
// and a whole circle as a circle, so a via's clearance is one face round the
// slab and not 32; points in a line are one line.
static TopoDS_Wire pathWire(const HNStepPoint *points, uint32_t count, double z, bool counterclockwise)
{
    // Points apart from the one before, the last apart from the first too.
    std::vector<HNStepPoint> path;
    path.reserve(count);
    for (uint32_t index = 0; index < count; index++) {
        if (path.empty() || std::hypot(points[index].x - path.back().x, points[index].y - path.back().y) > 1.0e-6) {
            path.push_back(points[index]);
        }
    }
    while (path.size() > 1 && std::hypot(path.front().x - path.back().x, path.front().y - path.back().y) <= 1.0e-6) {
        path.pop_back();
    }
    const size_t n = path.size();
    if (n < 3) {
        return TopoDS_Wire();
    }

    // The signed turn at each point, from the edge into it to the edge out.
    std::vector<double> turn(n);
    for (size_t index = 0; index < n; index++) {
        const HNStepPoint &a = path[(index + n - 1) % n];
        const HNStepPoint &b = path[index];
        const HNStepPoint &c = path[(index + 1) % n];
        const double inX = b.x - a.x, inY = b.y - a.y;
        const double outX = c.x - b.x, outY = c.y - b.y;
        turn[index] = std::atan2(inX * outY - inY * outX, inX * outX + inY * outY);
    }
    auto isArcTurn = [](double value, double sign) {
        return value * sign > arcMinimumTurn && value * sign < arcMaximumTurn;
    };
    auto at = [&path, n](size_t index) -> const HNStepPoint & { return path[index % n]; };
    auto pointAt = [z](const HNStepPoint &p) { return gp_Pnt(p.x, p.y, z); };

    BRepBuilderAPI_MakeWire wire;
    const bool wholeCircle = n >= 8 && [&]() {
        const double sign = turn[0] > 0.0 ? 1.0 : -1.0;
        for (double value : turn) {
            if (!isArcTurn(value, sign)) {
                return false;
            }
        }
        double centerX = 0.0, centerY = 0.0, radius = 0.0;
        if (!circleThrough(path[0], path[n / 3], path[2 * n / 3], centerX, centerY, radius)) {
            return false;
        }
        for (size_t index = 0; index < n; index++) {
            const HNStepPoint &p = path[index];
            const HNStepPoint &q = path[(index + 1) % n];
            const double halfChord = std::min(std::hypot(q.x - p.x, q.y - p.y) / 2.0, radius);
            if (std::fabs(std::hypot(p.x - centerX, p.y - centerY) - radius) > pathTolerance
                || radius - std::sqrt(radius * radius - halfChord * halfChord) > arcMaximumSagitta) {
                return false;
            }
        }
        const gp_Circ circle(gp_Ax2(gp_Pnt(centerX, centerY, z), gp_Dir(0.0, 0.0, 1.0)), radius);
        BRepBuilderAPI_MakeEdge edge(circle);
        if (!edge.IsDone()) {
            return false;
        }
        wire.Add(edge.Edge());
        return wire.IsDone();
    }();

    if (!wholeCircle) {
        // Start at the sharpest corner, so no arc is split across the start
        // where the path has a corner to start at.
        size_t first = 0;
        for (size_t index = 1; index < n; index++) {
            if (std::fabs(turn[index]) > std::fabs(turn[first])) {
                first = index;
            }
        }
        std::map<size_t, TopoDS_Vertex> vertices;
        auto vertex = [&](size_t offset) {
            const size_t index = (first + offset) % n;
            auto found = vertices.find(index);
            if (found == vertices.end()) {
                found = vertices.emplace(index, BRepBuilderAPI_MakeVertex(pointAt(path[index])).Vertex()).first;
            }
            return found->second;
        };
        auto point = [&](size_t offset) -> const HNStepPoint & { return at(first + offset); };
        auto turnAt = [&](size_t offset) { return turn[(first + offset) % n]; };
        // Every point from start to end within the tolerance of the circle
        // through start, their middle and end; that circle, if so.
        auto fitsArc = [&](size_t start, size_t end, double &centerX, double &centerY, double &radius) {
            if (!circleThrough(point(start), point((start + end) / 2), point(end), centerX, centerY, radius)
                || radius > 1000.0) {
                return false;
            }
            for (size_t offset = start + 1; offset < end; offset++) {
                const HNStepPoint &p = point(offset);
                if (std::fabs(std::hypot(p.x - centerX, p.y - centerY) - radius) > pathTolerance) {
                    return false;
                }
            }
            for (size_t offset = start; offset < end; offset++) {
                const HNStepPoint &a = point(offset);
                const HNStepPoint &b = point(offset + 1);
                const double halfChord = std::min(std::hypot(b.x - a.x, b.y - a.y) / 2.0, radius);
                if (radius - std::sqrt(radius * radius - halfChord * halfChord) > arcMaximumSagitta) {
                    return false;
                }
            }
            return true;
        };
        auto fitsLine = [&](size_t start, size_t end) {
            const HNStepPoint &a = point(start);
            const HNStepPoint &b = point(end);
            const double length = std::hypot(b.x - a.x, b.y - a.y);
            if (length <= 1.0e-9) {
                return false;
            }
            for (size_t offset = start + 1; offset < end; offset++) {
                const HNStepPoint &p = point(offset);
                if (std::fabs((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) / length > pathTolerance
                    || std::fabs(turnAt(offset)) > 0.01) {
                    return false;
                }
            }
            return true;
        };

        size_t offset = 0;
        while (offset < n) {
            // An arc: at least three chords turning alike, short of a whole
            // turn, within the tolerance of one circle.
            size_t arcEnd = offset;
            const double sign = turnAt(offset + 1) > 0.0 ? 1.0 : -1.0;
            double sweep = 0.0;
            double centerX = 0.0, centerY = 0.0, radius = 0.0;
            if (offset + 3 <= n && isArcTurn(turnAt(offset + 1), sign) && isArcTurn(turnAt(offset + 2), sign)) {
                size_t end = offset + 3;
                sweep = std::fabs(turnAt(offset + 1)) + std::fabs(turnAt(offset + 2));
                double x = 0.0, y = 0.0, r = 0.0;
                while (end <= n && fitsArc(offset, end, x, y, r)) {
                    arcEnd = end;
                    centerX = x;
                    centerY = y;
                    radius = r;
                    if (end == n || !isArcTurn(turnAt(end), sign) || sweep + std::fabs(turnAt(end)) > 5.0) {
                        break;
                    }
                    sweep += std::fabs(turnAt(end));
                    end++;
                }
            }
            if (arcEnd >= offset + 3) {
                Handle(Geom_TrimmedCurve) arc;
                GC_MakeArcOfCircle makeArc(pointAt(point(offset)), pointAt(point((offset + arcEnd) / 2)), pointAt(point(arcEnd)));
                if (makeArc.IsDone()) {
                    BRepBuilderAPI_MakeEdge edge(makeArc.Value(), vertex(offset), vertex(arcEnd % n == 0 ? 0 : arcEnd));
                    if (edge.IsDone()) {
                        wire.Add(edge.Edge());
                        offset = arcEnd;
                        continue;
                    }
                }
            }
            // A line, over the points in line with it.
            size_t lineEnd = offset + 1;
            while (lineEnd + 1 <= n && fitsLine(offset, lineEnd + 1)) {
                lineEnd++;
            }
            BRepBuilderAPI_MakeEdge edge(vertex(offset), vertex(lineEnd % n == 0 ? 0 : lineEnd));
            if (!edge.IsDone()) {
                return TopoDS_Wire();
            }
            wire.Add(edge.Edge());
            offset = lineEnd;
        }
    }
    if (!wire.IsDone()) {
        return TopoDS_Wire();
    }
    int edgeCount = 0;
    for (TopoDS_Iterator edges(wire.Wire()); edges.More(); edges.Next()) {
        edgeCount++;
    }
    if (!wholeCircle && edgeCount < 2) {
        return TopoDS_Wire();
    }
    TopoDS_Wire result = wire.Wire();
    if ((signedArea(path.data(), static_cast<uint32_t>(n)) > 0.0) != counterclockwise) {
        result = TopoDS::Wire(result.Reversed());
    }
    return result;
}

// A copper fragment's face at height z: its outline less its holes, or a null
// face when its outline makes none. A hole that makes no wire is left out.
static TopoDS_Face fragmentFace(const HNStepPoint *points, const uint32_t *pathPointCounts, uint32_t pathCount,
                                double z)
{
    const gp_Pln plane(gp_Pnt(0.0, 0.0, z), gp_Dir(0.0, 0.0, 1.0));
    TopoDS_Face face;
    for (uint32_t pathIndex = 0; pathIndex < pathCount; pathIndex++) {
        const uint32_t pointCount = pathPointCounts[pathIndex];
        const HNStepPoint *path = points;
        points += pointCount;
        if (pathIndex > 0 && face.IsNull()) {
            break;
        }
        const TopoDS_Wire wire = pathWire(path, pointCount, z, pathIndex == 0);
        if (wire.IsNull()) {
            continue;
        }
        if (pathIndex == 0) {
            BRepBuilderAPI_MakeFace makeFace(plane, wire, true);
            if (makeFace.IsDone()) {
                face = makeFace.Face();
            }
        }
        else {
            BRepBuilderAPI_MakeFace addHole(face);
            addHole.Add(wire);
            if (addHole.IsDone()) {
                face = addHole.Face();
            }
        }
    }
    return face;
}

// A copper layer's slabs: each fragment's outline less its holes, at the
// layer's height, as tall as its copper is thick.
static TopoDS_Shape copperLayerShape(const HNStepCopperLayer &layer)
{
    if (layer.points == nullptr || layer.pathPointCounts == nullptr || layer.fragmentPathCounts == nullptr
        || layer.thickness <= 0.0) {
        return TopoDS_Shape();
    }

    TopoDS_Compound compound;
    TopoDS_Builder builder;
    builder.MakeCompound(compound);
    bool empty = true;
    const HNStepPoint *points = layer.points;
    const uint32_t *pathPointCounts = layer.pathPointCounts;
    for (uint32_t fragmentIndex = 0; fragmentIndex < layer.fragmentCount; fragmentIndex++) {
        const uint32_t pathCount = layer.fragmentPathCounts[fragmentIndex];
        const TopoDS_Face face = fragmentFace(points, pathPointCounts, pathCount, layer.z);
        for (uint32_t pathIndex = 0; pathIndex < pathCount; pathIndex++) {
            points += pathPointCounts[pathIndex];
        }
        pathPointCounts += pathCount;
        if (face.IsNull()) {
            continue;
        }
        BRepPrimAPI_MakePrism prism(face, gp_Vec(0.0, 0.0, layer.thickness));
        if (!prism.IsDone() || prism.Shape().IsNull()) {
            continue;
        }
        builder.Add(compound, prism.Shape());
        empty = false;
    }
    return empty ? TopoDS_Shape() : TopoDS_Shape(compound);
}

bool HNStepExportBoardWithOptions(
    const char *path,
    const HNStepPoint *outline,
    uint32_t outlineCount,
    const HNStepHole *holes,
    uint32_t holeCount,
    double thickness,
    const char *name,
    const HNStepModelInstance *models,
    uint32_t modelCount,
    const HNStepExportOptions *options,
    HNStepExportReport *report
) {
    if (report != nullptr) {
        report->omittedModelCount = 0;
    }
    if (path == nullptr || outline == nullptr || outlineCount < 3 || thickness <= 0.0) {
        return false;
    }

    Handle(XCAFApp_Application) application = XCAFApp_Application::GetApplication();
    Handle(TDocStd_Document) document;
    application->NewDocument("MDTV-XCAF", document);
    XCAFDoc_ShapeTool::SetAutoNaming(false);
    BRepBuilderAPI::Precision(1.0e-6);

    TopoDS_Shape boardFace = faceFromOutline(outline, outlineCount);
    if (boardFace.IsNull()) {
        document->Close();
        return false;
    }

    if (holes != nullptr && holeCount > 0) {
        NCollection_List<TopoDS_Shape> boardShapes;
        NCollection_List<TopoDS_Shape> cutouts;
        boardShapes.Append(boardFace);
        for (uint32_t index = 0; index < holeCount; index++) {
            if (holes[index].diameter > 0.0) {
                cutouts.Append(faceFromHole(holes[index]));
            }
        }
        if (!cutouts.IsEmpty()) {
            BRepAlgoAPI_Cut cut;
            cut.SetArguments(boardShapes);
            cut.SetTools(cutouts);
            cut.SetRunParallel(true);
            cut.Build();
            if (cut.IsDone() && !cut.Shape().IsNull()) {
                boardFace = cut.Shape();
            }
        }
    }

    TopoDS_Shape boardShape = BRepPrimAPI_MakePrism(boardFace, gp_Vec(0.0, 0.0, thickness)).Shape();
    if (boardShape.IsNull()) {
        document->Close();
        return false;
    }

    Handle(XCAFDoc_ShapeTool) shapeTool = XCAFDoc_DocumentTool::ShapeTool(document->Main());
    Handle(XCAFDoc_ColorTool) colorTool = XCAFDoc_DocumentTool::ColorTool(document->Main());
    TDF_Label assemblyLabel = shapeTool->NewShape();
    const char *labelName = name == nullptr || std::strlen(name) == 0 ? "Horizontal PCA" : name;
    TDataStd_Name::Set(assemblyLabel, labelName);
    TDF_Label boardLabel = shapeTool->AddShape(boardShape, false);
    TDataStd_Name::Set(boardLabel, "Board");
    shapeTool->AddComponent(assemblyLabel, boardLabel, TopLoc_Location());
    colorTool->SetColor(boardLabel, Quantity_Color(0.08, 0.38, 0.16, Quantity_TOC_RGB), XCAFDoc_ColorGen);

    // Each copper layer is one part of the assembly, named for its layer.
    bool wroteCopper = false;
    if (options != nullptr && options->copperLayers != nullptr) {
        for (uint32_t index = 0; index < options->copperLayerCount; index++) {
            const HNStepCopperLayer &layer = options->copperLayers[index];
            const TopoDS_Shape copper = copperLayerShape(layer);
            if (copper.IsNull()) {
                continue;
            }
            TDF_Label copperLabel = shapeTool->AddShape(copper, false);
            const char *layerName = layer.name == nullptr || std::strlen(layer.name) == 0 ? "Copper" : layer.name;
            TDataStd_Name::Set(copperLabel, layerName);
            TDF_Label component = shapeTool->AddComponent(assemblyLabel, copperLabel, TopLoc_Location());
            if (!component.IsNull()) {
                TDataStd_Name::Set(component, layerName);
            }
            colorTool->SetColor(copperLabel, Quantity_Color(0.80, 0.50, 0.20, Quantity_TOC_RGB), XCAFDoc_ColorGen);
            wroteCopper = true;
        }
    }

    // Place component 3D models. Each unique model file is loaded once and
    // added as one shape, when a placement of it is first kept; multiple
    // placements reference it as separate components.
    const double minimumSize = options == nullptr ? 0.0 : options->minimumModelSize;
    if (models != nullptr && modelCount > 0) {
        std::map<std::string, TopoDS_Shape> modelShapes;
        std::map<std::string, TDF_Label> modelLabels;
        std::map<std::string, double> sizes;
        for (uint32_t index = 0; index < modelCount; index++) {
            const HNStepModelInstance &instance = models[index];
            if (instance.path == nullptr || std::strlen(instance.path) == 0) {
                continue;
            }
            const std::string key(instance.path);
            auto loaded = modelShapes.find(key);
            if (loaded == modelShapes.end()) {
                // A model that fails to load is remembered as a null shape.
                loaded = modelShapes.emplace(key, loadModelShape(instance.path)).first;
            }
            const TopoDS_Shape &modelShape = loaded->second;
            if (modelShape.IsNull()) {
                continue;
            }

            if (minimumSize > 0.0) {
                auto size = sizes.find(key);
                if (size == sizes.end()) {
                    size = sizes.emplace(key, modelSize(modelShape)).first;
                }
                if (size->second < minimumSize) {
                    if (report != nullptr) {
                        report->omittedModelCount++;
                    }
                    continue;
                }
            }

            TDF_Label modelLabel;
            auto cached = modelLabels.find(key);
            if (cached != modelLabels.end()) {
                modelLabel = cached->second;
            }
            else {
                modelLabel = shapeTool->AddShape(modelShape, false);
                modelLabels.emplace(key, modelLabel);
            }
            if (modelLabel.IsNull()) {
                continue;
            }

            const TopLoc_Location location = modelLocation(
                instance.bottom,
                instance.posX, instance.posY, instance.rotation,
                instance.offsetX, instance.offsetY, instance.offsetZ,
                instance.orientRoll, instance.orientPitch, instance.orientYaw,
                thickness
            );
            TDF_Label component = shapeTool->AddComponent(assemblyLabel, modelLabel, location);
            if (!component.IsNull() && instance.name != nullptr && std::strlen(instance.name) > 0) {
                TDataStd_Name::Set(component, instance.name);
            }
        }
    }

#if (OCC_VERSION_MAJOR > 7) || (OCC_VERSION_MAJOR == 7 && OCC_VERSION_MINOR >= 2)
    shapeTool->UpdateAssemblies();
#endif

    STEPCAFControl_Writer writer;
    writer.SetColorMode(true);
    writer.SetNameMode(true);
    // The writer's SplitCommonVertex compares every pair of a face's wires
    // vertex by vertex, which a copper plane with thousands of clearances
    // never gets through. Every copper path is a wire of its own vertices,
    // so it has nothing to split there; DirectFaces, the writer's other
    // default, still runs. Nor are an edge's curves on its faces written
    // beside the edge, which a reader works out from the edge itself: on
    // copper they were half the file. A board without copper is written as
    // before.
    bool transferred = false;
    if (wroteCopper) {
        ShapeProcess::OperationsFlags flags;
        flags.set(ShapeProcess::Operation::DirectFaces);
        writer.SetShapeProcessFlags(flags);
        DESTEP_Parameters parameters;
        parameters.InitFromStatic();
        parameters.WriteSurfaceCurMode = false;
        transferred = writer.Transfer(document, parameters, STEPControl_AsIs);
    }
    else {
        transferred = writer.Transfer(document, STEPControl_AsIs);
    }
    if (!transferred) {
        document->Close();
        return false;
    }

    IFSelect_ReturnStatus writeStatus = writer.Write(path);
    document->Close();
    return writeStatus == IFSelect_RetDone;
}

bool HNStepExportBoardWithModels(
    const char *path,
    const HNStepPoint *outline,
    uint32_t outlineCount,
    const HNStepHole *holes,
    uint32_t holeCount,
    double thickness,
    const char *name,
    const HNStepModelInstance *models,
    uint32_t modelCount
) {
    return HNStepExportBoardWithOptions(
        path, outline, outlineCount, holes, holeCount, thickness, name, models, modelCount, nullptr, nullptr
    );
}

bool HNStepExportBoard(
    const char *path,
    const HNStepPoint *outline,
    uint32_t outlineCount,
    const HNStepHole *holes,
    uint32_t holeCount,
    double thickness,
    const char *name
) {
    return HNStepExportBoardWithModels(path, outline, outlineCount, holes, holeCount, thickness, name, nullptr, 0);
}
