#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HNStepVertex {
    float x;
    float y;
    float z;
    float nx;
    float ny;
    float nz;
    float r;
    float g;
    float b;
} HNStepVertex;

typedef struct HNStepMesh {
    HNStepVertex *vertices;
    uint32_t vertexCount;
    uint32_t *indices;
    uint32_t indexCount;
} HNStepMesh;

typedef struct HNStepPoint {
    double x;
    double y;
} HNStepPoint;

typedef struct HNStepHole {
    double x;
    double y;
    double diameter;
    bool plated;
} HNStepHole;

// One placed 3D component model. All lengths in millimeters, all angles in
// radians. `path` is the STEP file for the model; `name` labels the instance
// (refdes). `bottom` marks a bottom-side (flipped) placement. pos*, the
// rotation, and the off*/orient* fields mirror getModelLocation.
typedef struct HNStepModelInstance {
    const char *path;
    const char *name;
    double posX;
    double posY;
    double rotation;
    bool bottom;
    double offsetX;
    double offsetY;
    double offsetZ;
    double orientRoll;
    double orientPitch;
    double orientYaw;
} HNStepModelInstance;

// Component placement as a row-major 3x4 matrix, so tests can pin the
// transform without loading a STEP file.
void HNStepModelPlacement(
    bool bottom, double posX, double posY, double rotation,
    double offsetX, double offsetY, double offsetZ,
    double roll, double pitch, double yaw, double boardThickness,
    double *outMatrix);

bool HNStepImport(const char *path, HNStepMesh *mesh);
void HNStepMeshFree(HNStepMesh *mesh);
bool HNStepExportBoard(
    const char *path,
    const HNStepPoint *outline,
    uint32_t outlineCount,
    const HNStepHole *holes,
    uint32_t holeCount,
    double thickness,
    const char *name
);

// Like HNStepExportBoard, but also loads and places component 3D models into the
// assembly. Models that fail to load are skipped (the board still exports).
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
);

#ifdef __cplusplus
}
#endif
