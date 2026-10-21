// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

// app/src/main/cpp/native-lib.cpp

#include <jni.h>
#include <vector>
#include <algorithm>
#include <cmath>
#include <cfloat>
#include <cstdlib>

// Custom rectangle structure
struct Rect {
    float x;
    float y;
    float width;
    float height;
};

// Detected object structure
struct DetectedObject {
    Rect rect;
    int index;
    float confidence;
};

// Quicksort for descending order
static void qsort_descent_inplace(std::vector<DetectedObject>& objects, int left, int right) {
    int i = left;
    int j = right;
    float p = objects[(left + right) / 2].confidence;
    while (i <= j) {
        while (objects[i].confidence > p) i++;
        while (objects[j].confidence < p) j--;
        if (i <= j) {
            std::swap(objects[i], objects[j]);
            i++; j--;
        }
    }
    if (left < j) qsort_descent_inplace(objects, left, j);
    if (i < right) qsort_descent_inplace(objects, i, right);
}

static void qsort_descent_inplace(std::vector<DetectedObject>& objects) {
    if (!objects.empty())
        qsort_descent_inplace(objects, 0, objects.size() - 1);
}

// Calculate intersection area (common area of two rectangles)
static float intersection_area(const DetectedObject &a, const DetectedObject &b) {
    float ax1 = a.rect.x;
    float ay1 = a.rect.y;
    float ax2 = a.rect.x + a.rect.width;
    float ay2 = a.rect.y + a.rect.height;
    float bx1 = b.rect.x;
    float by1 = b.rect.y;
    float bx2 = b.rect.x + b.rect.width;
    float by2 = b.rect.y + b.rect.height;

    float interX1 = std::max(ax1, bx1);
    float interY1 = std::max(ay1, by1);
    float interX2 = std::min(ax2, bx2);
    float interY2 = std::min(ay2, by2);

    float interWidth = std::max(0.0f, interX2 - interX1);
    float interHeight = std::max(0.0f, interY2 - interY1);

    return interWidth * interHeight;
}

// Non-Maximum Suppression (NMS) implementation (for already sorted proposals).
// FaunaPulse (round 170, perf review E7): stops once max_picked survivors are
// collected. The proposals arrive sorted by score and survivors are appended in
// that order, so the first max_picked survivors are exactly the ones the
// caller's truncation kept anyway — identical output, less work on noisy frames
// with more than max_picked survivors (the Kotlin postprocessEndToEnd path
// already breaks early the same way).
static void nms_sorted_bboxes(const std::vector<DetectedObject>& objects, std::vector<int>& picked, float nms_threshold, int max_picked) {
    picked.clear();
    int n = objects.size();
    std::vector<float> areas(n);
    for (int i = 0; i < n; i++) {
        areas[i] = objects[i].rect.width * objects[i].rect.height;
    }
    for (int i = 0; i < n; i++) {
        if ((int)picked.size() >= max_picked) break;
        const DetectedObject &a = objects[i];
        bool keep = true;
        for (int j = 0; j < (int)picked.size(); j++) {
            const DetectedObject &b = objects[picked[j]];
            float inter_area = intersection_area(a, b);
            float union_area = areas[i] + areas[picked[j]] - inter_area;
            if (union_area > 0 && (inter_area / union_area > nms_threshold)) {
                keep = false;
                break;
            }
        }
        if (keep)
            picked.push_back(i);
    }
}

extern "C"
JNIEXPORT jobjectArray JNICALL
Java_com_ultralytics_yolo_ObjectDetector_postprocess(
        JNIEnv *env,
        jobject thiz,
        jfloatArray recognitions,
        jint w, jint h,
        jfloat confidence_threshold,
        jfloat iou_threshold,
        jint num_items_threshold,
        jint num_classes) {

    // Read the flat [h x w] prediction tensor directly - one pin, no per-row marshaling or nested copies.
    jfloat *data = env->GetFloatArrayElements(recognitions, nullptr);
    if (data == nullptr) return NULL;

    // Extract box candidates (proposals); confidence first so box reads are skipped for rejected anchors
    std::vector<DetectedObject> proposals;
    for (int i = 0; i < w; ++i) {
        int class_index = 0;
        float class_score = -FLT_MAX;
        // Get each class score (class scores start at row 4)
        for (int c = 0; c < num_classes; c++) {
            float score = data[(c + 4) * w + i];
            if (score > class_score) {
                class_score = score;
                class_index = c;
            }
        }
        // Only add to candidates if score exceeds threshold
        if (class_score > confidence_threshold) {
            // Get center coordinates and width/height, convert to top-left coordinates
            float cx = data[i];
            float cy = data[w + i];
            float w_box = data[2 * w + i];
            float h_box = data[3 * w + i];

            DetectedObject obj;
            obj.rect.x = cx - w_box / 2;
            obj.rect.y = cy - h_box / 2;
            obj.rect.width = w_box;
            obj.rect.height = h_box;
            obj.index = class_index;
            obj.confidence = class_score;

            proposals.push_back(obj);
        }
    }
    env->ReleaseFloatArrayElements(recognitions, data, JNI_ABORT);

    // Sort by score
    qsort_descent_inplace(proposals);

    // Apply Non-Maximum Suppression (NMS); collects at most num_items_threshold
    // survivors (the min() below stays as a guard, it can no longer bite).
    std::vector<int> picked;
    nms_sorted_bboxes(proposals, picked, iou_threshold, num_items_threshold);

    int count = std::min((int)picked.size(), (int)num_items_threshold);
    std::vector<DetectedObject> objects(count);
    for (int i = 0; i < count; i++) {
        objects[i] = proposals[picked[i]];
        // No additional conversion needed here for the Java version
    }

    // Return results as 2D array (each element: [x, y, width, height, confidence, class_index])
    jclass floatArrayCls = env->FindClass("[F");
    if (floatArrayCls == NULL) return NULL;
    jobjectArray objArray = env->NewObjectArray(objects.size(), floatArrayCls, NULL);
    if (objArray == NULL) return NULL;
    for (int i = 0; i < objects.size(); i++) {
        float box[6] = {
                objects[i].rect.x,
                objects[i].rect.y,
                objects[i].rect.width,
                objects[i].rect.height,
                objects[i].confidence,
                static_cast<float>(objects[i].index)
        };
        jfloatArray iarr = env->NewFloatArray(6);
        if (iarr == NULL) return NULL;
        env->SetFloatArrayRegion(iarr, 0, 6, box);
        env->SetObjectArrayElement(objArray, i, iarr);
        env->DeleteLocalRef(iarr);
    }
    return objArray;
}

// FaunaPulse (round 319, part 2): give freed native memory back to Android.
//
// On a 3.6 GB phone the CPU copy of BioCLIP 2 grew the native heap to about 1.25 GB. After the
// model was closed the heap held only 55 MB of live data, but the allocator kept the freed
// 1.37 GB in the process (dumpsys meminfo: Native Heap PSS still 1.25 GB, Heap Free 1.37 GB),
// so the app stayed big and Android ended it once it was in the background.
//
// Android's allocator (scudo, or jemalloc on some phones) gives such pages back by itself about
// one second after the last free (the decay time the system sets for every app); mallopt makes
// it do so at once. What each option does, from the AOSP sources (bionic malloc_common.cpp,
// jemalloc_wrapper.cpp, external/scudo wrappers_c.inc):
//   M_PURGE_ALL  Android 14+: scudo also empties its caches; jemalloc treats it as M_PURGE.
//                Android 12 and 13 do not know it and answer 0.
//   M_PURGE      Android 9+: scudo releases its free pages and cached large blocks; jemalloc
//                purges all arenas (and the calling thread's cache).
//   M_DECAY_TIME 0 = give back at every free from now on, 1 = after about a second (what
//                Zygote sets for apps, so step 3 below puts that back).
// The Redmi test phone (Android 12) answered 1 to M_PURGE_ALL but nothing came back (RSS 1553 ->
// 1552 MB), so the caller (NativeMemory.kt) checks each step by the app's RSS, not by its answer,
// and tries the next one when nothing moved.
//
// mallopt is looked up at run time in libc itself: the plugin's floor is Android 6 and the
// function exists from Android 8; older phones get -1 back.
#include <dlfcn.h>
#include <malloc.h>
#ifndef M_DECAY_TIME
#define M_DECAY_TIME (-100)
#endif
#ifndef M_PURGE
#define M_PURGE (-101)
#endif
#ifndef M_PURGE_ALL
#define M_PURGE_ALL (-104)
#endif

using MalloptFn = int (*)(int, int);

static MalloptFn libcMallopt() {
    static MalloptFn fn = [] {
        // libc's own symbol, not the first "mallopt" in the global lookup order.
        void* libc = dlopen("libc.so", RTLD_NOW | RTLD_NOLOAD);
        void* sym = libc != nullptr ? dlsym(libc, "mallopt") : nullptr;
        if (sym == nullptr) sym = dlsym(RTLD_DEFAULT, "mallopt");
        return reinterpret_cast<MalloptFn>(sym);
    }();
    return fn;
}

// step 1 = M_PURGE_ALL, 2 = M_PURGE, 3 = decay time 0, M_PURGE, decay time back to 1.
// Returns mallopt's answer (1 = done, 0 = this Android does not know the option), or -1 when
// mallopt is missing or the step is unknown.
extern "C"
JNIEXPORT jint JNICALL
Java_com_ultralytics_yolo_NativeMemory_purge(JNIEnv *, jclass, jint step) {
    MalloptFn fn = libcMallopt();
    if (fn == nullptr) return -1;
    switch (step) {
        case 1: return fn(M_PURGE_ALL, 0);
        case 2: return fn(M_PURGE, 0);
        case 3: {
            fn(M_DECAY_TIME, 0);
            int rc = fn(M_PURGE, 0);
            fn(M_DECAY_TIME, 1);
            return rc;
        }
        default: return -1;
    }
}

// The file that provides the mallopt used above (for the log line), or null.
extern "C"
JNIEXPORT jstring JNICALL
Java_com_ultralytics_yolo_NativeMemory_malloptLibrary(JNIEnv *env, jclass) {
    MalloptFn fn = libcMallopt();
    Dl_info info;
    if (fn == nullptr || dladdr(reinterpret_cast<void*>(fn), &info) == 0 || info.dli_fname == nullptr) return nullptr;
    return env->NewStringUTF(info.dli_fname);
}
