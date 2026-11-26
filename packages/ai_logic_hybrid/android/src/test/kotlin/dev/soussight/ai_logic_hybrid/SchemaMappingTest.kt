package dev.soussight.ai_logic_hybrid

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

internal class SchemaMappingTest {
    private val watchSchema: Map<String, Any?> = mapOf(
        "type" to "object",
        "description" to "Watch verdict",
        "properties" to mapOf(
            "verdict" to mapOf("type" to "string", "enum" to listOf("ready", "not_yet", "unsure")),
            "whatISee" to mapOf("type" to "string"),
            "confidence" to mapOf("type" to "number"),
            "count" to mapOf("type" to "integer"),
            "obscured" to mapOf("type" to "boolean"),
            "items" to mapOf(
                "type" to "array",
                "items" to mapOf("type" to "string"),
                "minItems" to 1,
                "maxItems" to 5,
            ),
        ),
        "required" to listOf("verdict", "whatISee"),
    )

    @Test
    fun mapsTheSubsetToSdkSchema() {
        val s = SchemaMapping.toSchema(watchSchema)
        assertEquals("OBJECT", s.type)
        assertEquals("Watch verdict", s.description)
        assertEquals(setOf("verdict", "whatISee"), s.required!!.toSet())
        val p = assertNotNull(s.properties)
        assertEquals("STRING", p["verdict"]!!.type)
        assertEquals(listOf("ready", "not_yet", "unsure"), p["verdict"]!!.enum)
        assertEquals("NUMBER", p["confidence"]!!.type)
        assertEquals("INTEGER", p["count"]!!.type)
        assertEquals("BOOLEAN", p["obscured"]!!.type)
        val items = p["items"]!!
        assertEquals("ARRAY", items.type)
        assertEquals("STRING", items.items!!.type)
        assertEquals(1, items.minItems)
        assertEquals(5, items.maxItems)
    }

    @Test
    fun rejectsAnythingOutsideTheSubset() {
        val bad = listOf(
            mapOf("type" to "object", "properties" to emptyMap<String, Any?>(), "additionalProperties" to false),
            mapOf("type" to "null"),
            mapOf("type" to "array"),
            mapOf("type" to "object"),
            mapOf("type" to "integer", "enum" to listOf("1")),
            mapOf("type" to "object", "properties" to mapOf("a" to mapOf("type" to "string")), "required" to listOf("b")),
        )
        for (schema in bad) {
            val e = assertFailsWith<HybridError> { SchemaMapping.toSchema(schema) }
            assertEquals(HybridErrorCode.UNSUPPORTED_INPUT, e.code, "schema $schema")
        }
    }

    @Test
    fun localInstructionCarriesTheSchema() {
        val text = SchemaMapping.localInstruction(mapOf("type" to "string", "enum" to listOf("a")))
        assertTrue(text.endsWith("""{"type":"string","enum":["a"]}"""))
    }

    @Test
    fun jsonTextIsCompactLikeDartJsonEncode() {
        assertEquals(
            """{"a":"q\"\\\n\u0001","b":[1,2.5,true,null],"c":{}}""",
            JsonText.encode(
                linkedMapOf("a" to "q\"\\\n\u0001", "b" to listOf(1, 2.5, true, null), "c" to emptyMap<String, Any?>()),
            ),
        )
    }
}
