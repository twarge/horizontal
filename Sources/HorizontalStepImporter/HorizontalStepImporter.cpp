#include "HorizontalStepImporter.h"

#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepBuilderAPI.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
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
#include <TopoDS_Iterator.hxx>
#include <XCAFApp_Application.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <STEPControl_Reader.hxx>
#include <gp_Ax1.hxx>
#include <gp_Ax2.hxx>
#include <gp_Circ.hxx>
#include <gp_Dir.hxx>
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

    // Place component 3D models. Each unique model file is loaded once and added
    // as one shape; multiple placements reference it as separate components.
    if (models != nullptr && modelCount > 0) {
        std::map<std::string, TDF_Label> modelLabels;
        for (uint32_t index = 0; index < modelCount; index++) {
            const HNStepModelInstance &instance = models[index];
            if (instance.path == nullptr || std::strlen(instance.path) == 0) {
                continue;
            }
            const std::string key(instance.path);
            TDF_Label modelLabel;
            auto cached = modelLabels.find(key);
            if (cached != modelLabels.end()) {
                modelLabel = cached->second;
            }
            else {
                TopoDS_Shape modelShape = loadModelShape(instance.path);
                if (modelShape.IsNull()) {
                    modelLabels.emplace(key, TDF_Label()); // remember the failure
                    continue;
                }
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
    if (!writer.Transfer(document, STEPControl_AsIs)) {
        document->Close();
        return false;
    }

    IFSelect_ReturnStatus writeStatus = writer.Write(path);
    document->Close();
    return writeStatus == IFSelect_RetDone;
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
