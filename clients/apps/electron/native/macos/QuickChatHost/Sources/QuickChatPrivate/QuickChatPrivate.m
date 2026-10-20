#import "QuickChatPrivate.h"

#import <objc/message.h>

// CAMeshTransform's vertex and face, as QuartzCore lays them out.
typedef struct {
    CGFloat x, y, z;
} QCPoint3D;

typedef struct {
    CGPoint from;
    QCPoint3D to;
} QCMeshVertex;

typedef struct {
    unsigned int indices[4];
    float w[4];
} QCMeshFace;

id QCMeshTransform(NSInteger columns, NSInteger rows, const CGPoint *sources) {
    const NSInteger vertexCount = (columns + 1) * (rows + 1);
    const NSInteger faceCount = columns * rows;
    QCMeshVertex *vertices = calloc(vertexCount, sizeof(QCMeshVertex));
    QCMeshFace *faces = calloc(faceCount, sizeof(QCMeshFace));
    for (NSInteger row = 0; row <= rows; row++) {
        for (NSInteger column = 0; column <= columns; column++) {
            const NSInteger index = row * (columns + 1) + column;
            vertices[index] = (QCMeshVertex){
                sources[index],
                {(CGFloat)column / columns, (CGFloat)row / rows, 0},
            };
        }
    }
    for (NSInteger row = 0; row < rows; row++) {
        for (NSInteger column = 0; column < columns; column++) {
            const unsigned int corner = (unsigned int)(row * (columns + 1) + column);
            faces[row * columns + column] = (QCMeshFace){
                {corner, corner + 1, corner + (unsigned int)columns + 2, corner + (unsigned int)columns + 1},
                {0, 0, 0, 0},
            };
        }
    }
    Class meshClass = NSClassFromString(@"CAMeshTransform");
    SEL factory = NSSelectorFromString(@"meshTransformWithVertexCount:vertices:faceCount:faces:depthNormalization:");
    NSCAssert(meshClass != Nil && [meshClass respondsToSelector:factory], @"CAMeshTransform is unavailable");
    id mesh = ((id (*)(Class, SEL, NSUInteger, QCMeshVertex *, NSUInteger, QCMeshFace *, NSString *))objc_msgSend)(
        meshClass, factory, vertexCount, vertices, faceCount, faces, @"none");
    free(vertices);
    free(faces);
    return mesh;
}
