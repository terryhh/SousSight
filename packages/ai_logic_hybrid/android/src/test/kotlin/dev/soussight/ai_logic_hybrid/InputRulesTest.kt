package dev.soussight.ai_logic_hybrid

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

internal class InputRulesTest {
    private fun request(
        mode: HybridMode = HybridMode.ONLY_ON_DEVICE,
        parts: List<HybridPart> = listOf(HybridPart.Text("hi")),
        system: String? = null,
        schema: Map<String, Any?>? = null,
        maxOutputTokens: Int = 256,
    ) = GenerateRequest("r", mode, "f", system, parts, schema, maxOutputTokens, 1000)

    private fun image(size: Int = 10) = HybridPart.InlineData(ByteArray(size), "image/jpeg")

    private fun rejected(r: GenerateRequest) =
        assertEquals(HybridErrorCode.UNSUPPORTED_INPUT, assertFailsWith<HybridError> { InputRules.validate(r) }.code)

    @Test
    fun acceptsTextAndOneImage() {
        InputRules.validate(request(parts = listOf(HybridPart.Text("look"), image())))
    }

    @Test
    fun attachmentLimitsApplyToEveryRoute() {
        for (mode in HybridMode.entries) {
            rejected(request(mode = mode, parts = listOf(image(), image())))
            rejected(request(mode = mode, parts = listOf(image(InputRules.MAX_IMAGE_BYTES + 1))))
            rejected(request(mode = mode, parts = listOf(HybridPart.InlineData(ByteArray(1), "application/pdf"))))
            rejected(request(mode = mode, parts = emptyList()))
        }
    }

    @Test
    fun audioOnlyWithOnlyInCloud() {
        val audio = listOf(HybridPart.InlineData(ByteArray(4), "audio/wav"))
        InputRules.validate(request(mode = HybridMode.ONLY_IN_CLOUD, parts = audio))
        for (mode in HybridMode.entries - HybridMode.ONLY_IN_CLOUD) rejected(request(mode = mode, parts = audio))
    }

    @Test
    fun imageDimensions() {
        InputRules.checkDimensions(768, 512)
        assertFailsWith<HybridError> { InputRules.checkDimensions(769, 10) }
        assertFailsWith<HybridError> { InputRules.checkDimensions(10, 1024) }
        assertFailsWith<HybridError> { InputRules.checkDimensions(-1, -1) }
    }

    @Test
    fun tokenEstimateMatchesTheDartFormula() {
        // ceil((10 + 6 + len('{"type":"string"}') = 17) / 4) = ceil(33 / 4) = 9; + 1000 + 100.
        val r = request(
            system = "0123456789",
            parts = listOf(HybridPart.Text("abcdef"), image()),
            schema = mapOf("type" to "string"),
            maxOutputTokens = 100,
        )
        assertEquals(1109L, InputRules.estimateLocalTokens(r))
    }

    @Test
    fun localBudgetOnlyBindsOnlyOnDevice() {
        val long = listOf(HybridPart.Text("x".repeat(4 * 3800)))
        rejected(request(mode = HybridMode.ONLY_ON_DEVICE, parts = long))
        // A route that may use the cloud is not bound by the local budget; the policy decides.
        InputRules.validate(request(mode = HybridMode.PREFER_ON_DEVICE, parts = long))
        InputRules.validate(request(mode = HybridMode.ONLY_IN_CLOUD, parts = long))
        // Exactly at the limit is allowed: 3744 + 256 = 4000.
        InputRules.validate(request(parts = listOf(HybridPart.Text("x".repeat(4 * 3744)))))
        rejected(request(parts = listOf(HybridPart.Text("x".repeat(4 * 3744 + 1)))))
    }

    @Test
    fun aHugeOutputReservationCannotWrapPastTheBudget() {
        val huge = request(parts = listOf(HybridPart.Text("hi")), maxOutputTokens = Int.MAX_VALUE)
        assertEquals(Int.MAX_VALUE.toLong() + 1, InputRules.estimateLocalTokens(huge))
        rejected(huge)
    }
}
