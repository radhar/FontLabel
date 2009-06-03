//
//  FontLabelStringDrawing.m
//  FontLabel
//
//  Created by Kevin Ballard on 5/5/09.
//  Copyright © 2009 Zynga Game Networks
//
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "FontLabelStringDrawing.h"

typedef struct fontTable {
	CFDataRef cmapTable;
	UInt16 segCountX2;
	UInt16 *endCodes;
	UInt16 *startCodes;
	UInt16 *idDeltas;
	UInt16 *idRangeOffsets;
} fontTable;

static fontTable *newFontTable(CFDataRef cmapTable) {
	fontTable *table = (struct fontTable *)malloc(sizeof(struct fontTable));
	table->cmapTable = CFRetain(cmapTable);
	return table;
}

static void freeFontTable(fontTable *table) {
	CFRelease(table->cmapTable);
	free(table);
}

// read the cmap table from the font
// we only know how to understand some of the table formats at the moment
static fontTable *readFontTableFromFont(CGFontRef font) {
	CFDataRef cmapTable = CGFontCopyTableForTag(font, 'cmap');
	NSCAssert1(cmapTable != NULL, @"CGFontCopyTableForTag returned NULL for 'cmap' tag in font %@",
			   (font ? [(id)CFCopyDescription(font) autorelease] : @"(null)"));
	const UInt8 * const bytes = CFDataGetBytePtr(cmapTable);
	NSCAssert1(OSReadBigInt16(bytes, 0) == 0, @"cmap table for font %@ has bad version number",
			   (font ? [(id)CFCopyDescription(font) autorelease] : @"(null)"));
	UInt16 numberOfSubtables = OSReadBigInt16(bytes, 2);
	const UInt8 *unicodeSubtable = NULL;
	const UInt8 * const encodingSubtables = &bytes[4];
	for (UInt16 i = 0; i < numberOfSubtables; i++) {
		const UInt8 * const encodingSubtable = &encodingSubtables[8 * i];
		UInt16 platformID = OSReadBigInt16(encodingSubtable, 0);
		UInt16 platformSpecificID = OSReadBigInt16(encodingSubtable, 2);
		if (platformID == 0) {
			if (platformSpecificID == 3 || unicodeSubtable == NULL) {
				UInt32 offset = OSReadBigInt32(encodingSubtable, 4);
				unicodeSubtable = &bytes[offset];
			}
		}
	}
	fontTable *table = NULL;
	if (unicodeSubtable != NULL) {
		UInt16 format = OSReadBigInt16(unicodeSubtable, 0);
		if (format == 4) {
			// subtable format 4
			table = newFontTable(cmapTable);
			//UInt16 length = OSReadBigInt16(unicodeSubtable, 2);
			//UInt16 language = OSReadBigInt16(unicodeSubtable, 4);
			table->segCountX2 = OSReadBigInt16(unicodeSubtable, 6);
			//UInt16 searchRange = OSReadBigInt16(unicodeSubtable, 8);
			//UInt16 entrySelector = OSReadBigInt16(unicodeSubtable, 10);
			//UInt16 rangeShift = OSReadBigInt16(unicodeSubtable, 12);
			table->endCodes = (UInt16*)&unicodeSubtable[14];
			table->startCodes = (UInt16*)&((UInt8*)table->endCodes)[table->segCountX2+2];
			table->idDeltas = (UInt16*)&((UInt8*)table->startCodes)[table->segCountX2];
			table->idRangeOffsets = (UInt16*)&((UInt8*)table->idDeltas)[table->segCountX2];
			//UInt16 *glyphIndexArray = &idRangeOffsets[segCountX2];
		}
	}
	CFRelease(cmapTable);
	return table;
}
// if we aren't given a valid font table, we use the magic number hack
// The convertNewlines argument specifies whether newlines should be treated as spaces.
// This is odd, but it mirrors -sizeWithFont: and -drawAtPoint:withFont:
static void mapCharactersToGlyphsInFont(const fontTable *table, size_t n, unichar characters[], CGGlyph outGlyphs[], BOOL convertNewlines) {
	if (table != NULL) {
		for (NSUInteger i = 0; i < n; i++) {
			unichar c = characters[i];
			if (convertNewlines && c == (unichar)'\n') c = (unichar)' ';
			UInt16 segOffset;
			BOOL foundSegment = NO;
			for (segOffset = 0; segOffset < table->segCountX2; segOffset += 2) {
				UInt16 endCode = OSReadBigInt16(table->endCodes, segOffset);
				if (endCode >= c) {
					foundSegment = YES;
					break;
				}
			}
			if (!foundSegment) {
				// no segment
				// this is an invalid font
				outGlyphs[i] = 0;
			} else {
				UInt16 startCode = OSReadBigInt16(table->startCodes, segOffset);
				if (!(startCode <= c)) {
					// the code falls in a hole between segments
					outGlyphs[i] = 0;
				} else {
					UInt16 idRangeOffset = OSReadBigInt16(table->idRangeOffsets, segOffset);
					if (idRangeOffset == 0) {
						UInt16 idDelta = OSReadBigInt16(table->idDeltas, segOffset);
						outGlyphs[i] = (c + idDelta) % 65536;
					} else {
						// use the glyphIndexArray
						UInt16 glyphOffset = idRangeOffset + 2 * (c - startCode);
						outGlyphs[i] = OSReadBigInt16(&((UInt8*)table->idRangeOffsets)[segOffset], glyphOffset);
					}
				}
			}
		}
	} else {
		for (NSUInteger i = 0; i < n; i++) { 
			unichar c = characters[i];
			if (convertNewlines && c == (unichar)'\n') c = (unichar)' ';
			// 29 is some weird magic number that works for lots of fonts
			outGlyphs[i] = c - 29;
		}
	}
}

static inline CGFloat getFontRatio(CGFontRef font, CGFloat pointSize) {
	return pointSize/CGFontGetUnitsPerEm(font);
}

static CGSize mapGlyphsToAdvancesInFont(CGFontRef font, CGFloat pointSize, size_t n,
										CGGlyph glyphs[], int outAdvances[], CGFloat outWidths[], CGFloat *outAscender) {
	CGSize retVal = CGSizeZero;
	if (CGFontGetGlyphAdvances(font, glyphs, n, outAdvances)) {
		CGFloat ratio = getFontRatio(font, pointSize);
		
		int width = 0;
		for (int i = 0; i < n; i++) {
			width += outAdvances[i];
			if (outWidths != NULL) outWidths[i] = outAdvances[i]*ratio;
		}
		
		CGFloat ascender = ceilf(CGFontGetAscent(font) * ratio);
		
		retVal.width = width*ratio;
		retVal.height = ceilf(CGFontGetAscent(font) * ratio) - floorf(CGFontGetDescent(font) * ratio);
		if (outAscender != NULL) *outAscender = ascender;
	} else if (outAscender != NULL) {
		*outAscender = 0.0f;
	}
	return retVal;
}

@implementation NSString (FontLabelStringDrawing)
- (CGSize)sizeWithCGFont:(CGFontRef)font pointSize:(CGFloat)pointSize {
	NSUInteger len = [self length];
	
	// Map the characters to glyphs
	unichar characters[len];
	CGGlyph glyphs[len];
	[self getCharacters:characters];
	fontTable *table = readFontTableFromFont(font);
	mapCharactersToGlyphsInFont(table, len, characters, glyphs, YES);
	freeFontTable(table);
	
	// Get the advances for the glyphs
	int advances[len];
	CGSize retVal = mapGlyphsToAdvancesInFont(font, pointSize, len, glyphs, advances, NULL, NULL);
	
	return CGSizeMake(ceilf(retVal.width), ceilf(retVal.height));
}

- (CGSize)sizeWithCGFont:(CGFontRef)font pointSize:(CGFloat)pointSize constrainedToSize:(CGSize)size {
	return [self sizeWithCGFont:font pointSize:pointSize constrainedToSize:size lineBreakMode:UILineBreakModeWordWrap];
}

/*
 According to experimentation with UIStringDrawing, this can actually return a CGSize whose height is greater
 than the one passed in. The two cases are as follows:
 1. If the given size parameter's height is smaller than a single line, the returned value will
 be the height of one line.
 2. If the given size parameter's height falls between multiples of a line height, and the wrapped string
 actually extends past the size.height, and the difference between size.height and the previous multiple
 of a line height is >= the font's ascender, then the returned size's height is extended to the next line.
 To put it simply, if the baseline point of a given line falls in the given size, the entire line will
 be present in the output size.
 */
// at the moment, only UILineBreakModeWordWrap is supported
- (CGSize)sizeWithCGFont:(CGFontRef)font pointSize:(CGFloat)pointSize constrainedToSize:(CGSize)size
		   lineBreakMode:(UILineBreakMode)lineBreakMode {
	NSUInteger len = [self length];
	
	// Map the characters to glyphs
	// split on hard newlines and calculate each run separately
	unichar characters[len];
	[self getCharacters:characters];
	fontTable *table = readFontTableFromFont(font);
	CGSize retVal = CGSizeZero;
	CGFloat ascender = 0;
	NSUInteger idx = 0;
	while (idx < len) {
		if (ascender > 0 && retVal.height + ascender > size.height) break;
		unichar *charPtr = &characters[idx];
		NSUInteger i;
		for (i = idx; i < len && characters[i] != (unichar)'\n'; i++);
		size_t rowLen = i - idx;
		CGGlyph glyphs[rowLen];
		mapCharactersToGlyphsInFont(table, rowLen, charPtr, glyphs, NO);
		// Get the advances for the glyphs
		int advances[rowLen];
		CGFloat widths[rowLen];
		CGSize rowSize = mapGlyphsToAdvancesInFont(font, pointSize, rowLen, glyphs, advances, widths, (ascender > 0 ? NULL : &ascender));
		NSUInteger rowIdx = 0;
		while (rowSize.width > size.width) {
			// wrap to a new line
			CGFloat curWidth = 0;
			NSUInteger lastSpace = 0;
			for (NSUInteger j = rowIdx; j < rowLen; j++) {
				curWidth += widths[j];
				if (curWidth > size.width) {
					// we've gone over the limit now
					// TODO: observe lineBreakMode
					// for the time being, just always treat it as a word wrap
					if (lastSpace == 0) {
						// this is the first word, fall back to character wrap instead
						rowIdx = j;
					} else {
						rowIdx = lastSpace;
						while (rowIdx < rowLen && charPtr[rowIdx] == (unichar)' ') rowIdx++;
					}
					break;
				} else if (charPtr[j] == (unichar)' ') {
					lastSpace = j;
				}
			}
			retVal.width = MAX(retVal.width, curWidth);
			retVal.height += rowSize.height;
			rowSize.width -= curWidth;
		}
		if (rowSize.width > 0) {
			retVal.width = MAX(retVal.width, rowSize.width);
			retVal.height += rowSize.height;
		}
	}
	freeFontTable(table);
	
	return CGSizeMake(ceilf(retVal.width), ceilf(retVal.height));
}

- (CGSize)drawAtPoint:(CGPoint)point withCGFont:(CGFontRef)font pointSize:(CGFloat)pointSize {
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	
	CGContextSetFont(ctx, font);
	CGContextSetFontSize(ctx, pointSize);
	
	CGGlyph glyphs[[self length]];
	
	// Map the characters to glyphs
	unichar characters[[self length]];
	[self getCharacters:characters];
	fontTable *table = readFontTableFromFont(font);
	mapCharactersToGlyphsInFont(table, [self length], characters, glyphs, YES);
	freeFontTable(table);
	
	// Get the advances for the glyphs
	int advances[[self length]];
	CGFloat ascender;
	CGSize retVal = mapGlyphsToAdvancesInFont(font, pointSize, [self length], glyphs, advances, NULL, &ascender);
	
	// flip it upside-down because our 0,0 is upper-left, whereas ttfs are for screens where 0,0 is lower-left
	CGAffineTransform textTransform = CGAffineTransformMake(1.0, 0.0, 0.0, -1.0, 0.0, 0.0);
	CGContextSetTextMatrix(ctx, textTransform);
	
	CGContextSetTextDrawingMode(ctx, kCGTextFill);
	CGContextShowGlyphsAtPoint(ctx, point.x, point.y + ascender, glyphs, [self length]);
	return retVal;
}
@end