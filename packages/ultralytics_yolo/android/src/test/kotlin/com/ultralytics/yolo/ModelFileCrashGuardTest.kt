package com.ultralytics.yolo

import com.google.flatbuffers.FlatBufferBuilder
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import org.tensorflow.lite.schema.Buffer
import org.tensorflow.lite.schema.Metadata
import org.tensorflow.lite.schema.Model
import org.tensorflow.lite.schema.SubGraph
import org.tensorflow.lite.schema.Tensor
import org.tensorflow.lite.support.metadata.schema.ModelMetadata
import org.tensorflow.lite.support.metadata.schema.SubGraphMetadata
import org.tensorflow.lite.support.metadata.schema.TensorMetadata
import java.io.ByteArrayInputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

// FaunaPulse (round 326): model files are user input (imported, or downloaded from a pasted
// link), so reading them must never close the app. The files here are built in the test
// (no binary fixtures in git).
class ModelFileCrashGuardTest {
    /**
     * A .tflite whose graph is a normal identification model (input [1,640,640,3], output
     * [1,10]), so it passes the Dart import check, but whose embedded TFLITE_METADATA claims
     * [inputTensorMetadataLength] entries. The metadata library allocates a list of that size
     * when it opens the file: 2 billion asks for about 8 GB (OutOfMemoryError).
     */
    private fun tfliteWithMetadataLength(inputTensorMetadataLength: Int): ByteArray {
        val mb = FlatBufferBuilder(256)
        // One entry per model input and output: the library refuses metadata whose counts
        // differ from the graph's.
        TensorMetadata.startTensorMetadata(mb)
        val inputMeta = TensorMetadata.endTensorMetadata(mb)
        TensorMetadata.startTensorMetadata(mb)
        val outputMeta = TensorMetadata.endTensorMetadata(mb)
        val inputs = SubGraphMetadata.createInputTensorMetadataVector(mb, intArrayOf(inputMeta))
        val outputs = SubGraphMetadata.createOutputTensorMetadataVector(mb, intArrayOf(outputMeta))
        SubGraphMetadata.startSubGraphMetadata(mb)
        SubGraphMetadata.addInputTensorMetadata(mb, inputs)
        SubGraphMetadata.addOutputTensorMetadata(mb, outputs)
        val subgraphMeta = SubGraphMetadata.endSubGraphMetadata(mb)
        val subgraphs = ModelMetadata.createSubgraphMetadataVector(mb, intArrayOf(subgraphMeta))
        ModelMetadata.startModelMetadata(mb)
        ModelMetadata.addSubgraphMetadata(mb, subgraphs)
        ModelMetadata.finishModelMetadataBuffer(mb, ModelMetadata.endModelMetadata(mb))
        val meta = mb.sizedByteArray()
        // Find the 4-byte length of the one-entry input list and overwrite it, checking with
        // the real reader that the right slot was changed.
        val slot = (0..meta.size - 4 step 4).first { i ->
            val probe = ByteBuffer.wrap(meta.clone()).order(ByteOrder.LITTLE_ENDIAN)
            probe.putInt(i, 12345)
            runCatching {
                ModelMetadata.getRootAsModelMetadata(probe).subgraphMetadata(0).inputTensorMetadataLength() == 12345
            }.getOrDefault(false)
        }
        ByteBuffer.wrap(meta).order(ByteOrder.LITTLE_ENDIAN).putInt(slot, inputTensorMetadataLength)

        val b = FlatBufferBuilder(1024)
        val inShape = Tensor.createShapeVector(b, intArrayOf(1, 640, 640, 3))
        Tensor.startTensor(b); Tensor.addShape(b, inShape); val inTensor = Tensor.endTensor(b)
        val outShape = Tensor.createShapeVector(b, intArrayOf(1, 10))
        Tensor.startTensor(b); Tensor.addShape(b, outShape); val outTensor = Tensor.endTensor(b)
        val tensors = SubGraph.createTensorsVector(b, intArrayOf(inTensor, outTensor))
        val graphInputs = SubGraph.createInputsVector(b, intArrayOf(0))
        val graphOutputs = SubGraph.createOutputsVector(b, intArrayOf(1))
        SubGraph.startSubGraph(b)
        SubGraph.addTensors(b, tensors)
        SubGraph.addInputs(b, graphInputs)
        SubGraph.addOutputs(b, graphOutputs)
        val graph = SubGraph.endSubGraph(b)
        val graphs = Model.createSubgraphsVector(b, intArrayOf(graph))
        val emptyData = Buffer.createDataVector(b, ByteArray(0))
        Buffer.startBuffer(b); Buffer.addData(b, emptyData); val buffer0 = Buffer.endBuffer(b)
        val metaData = Buffer.createDataVector(b, meta)
        Buffer.startBuffer(b); Buffer.addData(b, metaData); val buffer1 = Buffer.endBuffer(b)
        val buffers = Model.createBuffersVector(b, intArrayOf(buffer0, buffer1))
        val metadata = Model.createMetadataVector(
            b, intArrayOf(Metadata.createMetadata(b, b.createString("TFLITE_METADATA"), 1L)),
        )
        Model.startModel(b)
        Model.addVersion(b, 3)
        Model.addSubgraphs(b, graphs)
        Model.addBuffers(b, buffers)
        Model.addMetadata(b, metadata)
        Model.finishModelBuffer(b, Model.endModel(b))
        return b.sizedByteArray()
    }

    @Test
    fun aNormalEmbeddedMetadataStillReads(@TempDir dir: File) {
        val file = File(dir, "ok.tflite").apply { writeBytes(tfliteWithMetadataLength(1)) }
        assertArrayEquals(intArrayOf(1, 640, 640, 3), YOLOFileUtils.inputTensorShapeFromPath(file.path))
    }

    @Test
    fun aHugeEmbeddedMetadataLengthIsReadAsNoMetadata(@TempDir dir: File) {
        val bytes = tfliteWithMetadataLength(2_000_000_000)
        // Before round 326 both calls threw OutOfMemoryError, which `catch (e: Exception)`
        // does not catch, so the app closed on every screen that lists the models.
        assertNull(YOLOFileUtils.metadataFromFlatbuffer(ByteBuffer.wrap(bytes), "huge_length.tflite"))
        val file = File(dir, "huge_length.tflite").apply { writeBytes(bytes) }
        assertNull(YOLOFileUtils.inputTensorShapeFromPath(file.path))
    }

    @Test
    fun onnxMetadataKeepsOnlyTheKeysTheAppReads() {
        fun entry(key: String, value: String): List<Byte> {
            val k = key.toByteArray()
            val v = value.toByteArray()
            val body = listOf(0x0a.toByte()) + varint(k.size.toLong()) + k.toList() +
                listOf(0x12.toByte()) + varint(v.size.toLong()) + v.toList()
            return listOf(0x72.toByte()) + varint(body.size.toLong()) + body
        }
        val bytes = entry("description", "x".repeat(1000)) + entry("task", "detect") +
            entry("names", "{0: 'bee'}") + entry("author", "someone")
        val props = YOLOFileUtils.readOnnxMetadataProps(ByteArrayInputStream(bytes.toByteArray()))
        // Unused entries are not kept, so many large ones cannot add up to more memory than
        // the app has (before round 326 up to 128 entries of 2 MB each were kept).
        assertEquals(mapOf("task" to "detect", "names" to "{0: 'bee'}"), props)
    }

    @Test
    fun photosAboveThePixelLimitAreRefusedBeforeDecoding() {
        assertTrue(photoFitsDecodeLimit(4000, 3000))
        assertTrue(photoFitsDecodeLimit(12000, 9000), "a 108 MP phone photo")
        assertTrue(!photoFitsDecodeLimit(16320, 12240), "a 200 MP photo, about 800 MB once decoded")
        assertTrue(!photoFitsDecodeLimit(30000, 30000), "a header claiming 900 MP")
        assertTrue(!photoFitsDecodeLimit(0, 100))
        assertTrue(!photoFitsDecodeLimit(-1, -1))
    }

    private fun varint(value: Long): List<Byte> {
        var remaining = value
        val result = mutableListOf<Byte>()
        while (true) {
            if (remaining and 0x7f.inv().toLong() == 0L) {
                result += remaining.toByte()
                return result
            }
            result += ((remaining and 0x7f) or 0x80).toByte()
            remaining = remaining ushr 7
        }
    }
}
