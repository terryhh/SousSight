package dev.soussight.ai_logic_hybrid

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class ProtocolTest {
    private fun generateArgs(vararg overrides: Pair<String, Any?>): Map<String, Any?> = mapOf(
        "requestId" to "r1",
        "mode" to "onlyOnDevice",
        "feature" to "pantry_scan",
        "systemInstruction" to "Be brief.",
        "parts" to listOf(mapOf("type" to "text", "text" to "hello")),
        "jsonSchema" to null,
        "maxOutputTokens" to 256,
        "timeoutMs" to 8000,
    ) + overrides

    @Test
    fun channelNamesMatchTheDartSide() {
        assertEquals("dev.soussight/ai_logic_hybrid", Protocol.METHOD_CHANNEL)
        assertEquals("dev.soussight/ai_logic_hybrid/prepare", Protocol.PREPARE_CHANNEL)
    }

    @Test
    fun enumWireNamesAreTheDartNames() {
        assertEquals(
            listOf("preferOnDevice", "onlyOnDevice", "preferInCloud", "onlyInCloud"),
            HybridMode.entries.map { it.wire },
        )
        assertEquals(listOf("preview", "previewFast", "stable"), AndroidModelOption.entries.map { it.wire })
        assertEquals(
            listOf("available", "downloadable", "downloading", "unavailable"),
            OnDeviceStatus.entries.map { it.wire },
        )
        assertEquals(listOf("onDevice", "cloud"), InferenceSourceWire.entries.map { it.wire })
        assertEquals(
            listOf(
                "unavailable", "unsupportedInput", "unsupportedMode", "busy", "quota", "blocked",
                "network", "attestation", "timeout", "cancelled", "failed",
            ),
            HybridErrorCode.entries.map { it.wire },
        )
    }

    @Test
    fun parsesConfigure() {
        val c = Protocol.parseConfig(
            mapOf("cloudModel" to "gemini-x", "androidModel" to "previewFast", "languages" to listOf("en", "ko")),
        )
        assertEquals(HybridConfig("gemini-x", AndroidModelOption.PREVIEW_FAST, listOf("en", "ko")), c)
    }

    @Test
    fun configureRejectsMissingModelAndUnknownOption() {
        assertEquals(
            HybridErrorCode.FAILED,
            assertFailsWith<HybridError> { Protocol.parseConfig(mapOf("androidModel" to "preview")) }.code,
        )
        assertEquals(
            HybridErrorCode.FAILED,
            assertFailsWith<HybridError> {
                Protocol.parseConfig(mapOf("cloudModel" to "m", "androidModel" to "nano4"))
            }.code,
        )
    }

    @Test
    fun parsesGenerateWithImageAndSchema() {
        val bytes = byteArrayOf(1, 2, 3)
        val schema = mapOf("type" to "object", "properties" to mapOf("a" to mapOf("type" to "string")))
        val r = Protocol.parseGenerate(
            generateArgs(
                "mode" to "preferOnDevice",
                "parts" to listOf(
                    mapOf("type" to "text", "text" to "what is this"),
                    mapOf("type" to "inlineData", "mimeType" to "image/jpeg", "bytes" to bytes),
                ),
                "jsonSchema" to schema,
                // StandardMessageCodec sends large ints as Long.
                "timeoutMs" to 30_000L,
            ),
        )
        assertEquals("r1", r.requestId)
        assertEquals(HybridMode.PREFER_ON_DEVICE, r.mode)
        assertEquals("pantry_scan", r.feature)
        assertEquals("Be brief.", r.systemInstruction)
        assertEquals(256, r.maxOutputTokens)
        assertEquals(30_000L, r.timeoutMs)
        assertEquals(schema, r.jsonSchema)
        assertIs<HybridPart.Text>(r.parts[0])
        val image = assertIs<HybridPart.InlineData>(r.parts[1])
        assertTrue(image.isImage)
        assertTrue(image.bytes.contentEquals(bytes))
    }

    @Test
    fun unknownModeIsUnsupportedMode() {
        val e = assertFailsWith<HybridError> { Protocol.parseGenerate(generateArgs("mode" to "auto")) }
        assertEquals(HybridErrorCode.UNSUPPORTED_MODE, e.code)
    }

    @Test
    fun unknownPartTypeIsUnsupportedInput() {
        val e = assertFailsWith<HybridError> {
            Protocol.parseGenerate(generateArgs("parts" to listOf(mapOf("type" to "fileData"))))
        }
        assertEquals(HybridErrorCode.UNSUPPORTED_INPUT, e.code)
    }

    @Test
    fun malformedGenerateArgumentsFail() {
        for (bad in listOf(
            generateArgs("requestId" to null),
            generateArgs("timeoutMs" to 0),
            generateArgs("maxOutputTokens" to null),
            generateArgs("parts" to "hello"),
            generateArgs("jsonSchema" to "object"),
        )) {
            assertEquals(HybridErrorCode.FAILED, assertFailsWith<HybridError> { Protocol.parseGenerate(bad) }.code)
        }
        assertEquals(
            HybridErrorCode.FAILED,
            assertFailsWith<HybridError> { Protocol.parseGenerate(null) }.code,
        )
    }

    @Test
    fun capabilitiesMatchTheContract() {
        val caps = Protocol.capabilities()
        assertEquals("android", caps["platform"])
        assertEquals(1, caps["maxImages"])
        assertEquals(1024 * 1024, caps["maxImageBytes"])
        assertEquals(768, caps["maxImageDimension"])
        assertEquals(
            listOf("preferOnDevice", "onlyOnDevice", "preferInCloud", "onlyInCloud"),
            caps["supportedModes"],
        )
        val local = caps["local"] as Map<*, *>
        assertEquals("Gemini Nano", local["modelFamily"])
        assertEquals(true, local["supportsImage"])
        assertEquals(false, local["supportsJsonSchema"])
        assertEquals(4000, local["maxTotalTokens"])
        assertEquals(256, local["defaultOutputReserve"])
        assertEquals(1000, local["imageTokenEstimate"])
        assertEquals(listOf("en", "ko"), local["validatedLanguages"])
        // Every key LocalModelLimits.fromMap / HybridCapabilities.fromMap reads.
        assertEquals(
            setOf("platform", "local", "maxImages", "maxImageBytes", "maxImageDimension", "supportedModes"),
            caps.keys,
        )
        assertEquals(
            setOf(
                "modelFamily", "supportsImage", "supportsJsonSchema", "maxTotalTokens",
                "defaultOutputReserve", "imageTokenEstimate", "validatedLanguages",
            ),
            local.keys,
        )
    }

    @Test
    fun resultAndAvailabilityMaps() {
        assertEquals(
            mapOf("requestId" to "r9", "text" to "ok", "source" to "onDevice", "modelLabel" to null),
            Protocol.resultMap("r9", GenerateResult("ok", InferenceSourceWire.ON_DEVICE, null)),
        )
        assertEquals(
            mapOf("status" to "unavailable", "reason" to "not_enrolled", "modelLabel" to null),
            Protocol.availabilityMap(AvailabilityResult(OnDeviceStatus.UNAVAILABLE, Reasons.NOT_ENROLLED)),
        )
        assertEquals(mapOf("fraction" to null), Protocol.fractionEvent(null))
        assertTrue(Protocol.parseWithImage(mapOf("withImage" to true)))
        assertEquals(false, Protocol.parseWithImage(null))
        assertNull(Protocol.parseRequestId(mapOf("x" to 1)))
    }
}
