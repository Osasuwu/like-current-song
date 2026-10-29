package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Whether a Data API like found the video already rated (#274). An undo of
 * a like the user had already given keeps the rating, so the answer decides
 * whether undo takes the like back; when it cannot be read, the like stays.
 */
class YouTubeMusicLikerRatedBeforeTest {

    private fun rating(value: String) = """{"items":[{"videoId":"vid","rating":"$value"}]}"""

    @Test
    fun `a video rated like before the press counts as already rated`() {
        assertEquals(true, YouTubeMusicLiker.ratedBefore(rating("like")))
    }

    @Test
    fun `an unrated video counts as not rated, so the undo takes the like back`() {
        assertEquals(false, YouTubeMusicLiker.ratedBefore(rating("none")))
    }

    @Test
    fun `a rating that cannot be read counts as rated, so the undo keeps the like`() {
        assertEquals(true, YouTubeMusicLiker.ratedBefore("""{"items":[]}"""))
        assertEquals(true, YouTubeMusicLiker.ratedBefore("not json"))
    }
}
