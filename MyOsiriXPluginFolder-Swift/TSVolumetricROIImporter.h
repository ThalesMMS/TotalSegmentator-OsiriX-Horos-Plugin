//
// TSVolumetricROIImporter.h
// TotalSegmentator
//
// Imports TotalSegmentator NIfTI masks as volumetric Horos/OsiriX brush ROIs.
//

#import <Foundation/Foundation.h>

@class ViewerController;

NS_ASSUME_NONNULL_BEGIN

@interface TSVolumetricROIImporter : NSObject

+ (NSDictionary<NSString *, id> *)importVolumetricROIsFromManifest:(NSString *)manifestPath
                                                        intoViewer:(ViewerController *)viewer
    NS_SWIFT_NAME(importVolumetricROIs(fromManifest:into:));

@end

NS_ASSUME_NONNULL_END
