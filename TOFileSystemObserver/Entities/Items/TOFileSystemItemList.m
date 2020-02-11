//
//  TOFileSystemItemList.m
//
//  Copyright 2019-2020 Timothy Oliver. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to
//  deal in the Software without restriction, including without limitation the
//  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
//  sell copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//  OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
//  IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import "TOFileSystemItemList.h"
#import "TOFileSystemItem.h"
#import "TOFileSystemItem+Private.h"
#import "TOFileSystemObserver.h"
#import "TOFileSystemPath.h"
#import "TOFileSystemNotificationToken.h"
#import "TOFileSystemNotificationToken+Private.h"
#import "TOFileSystemItemListChanges.h"
#import "TOFileSystemItemListChanges+Private.h"

#import "NSURL+TOFileSystemUUID.h"
#import "NSFileManager+TOFileSystemDirectoryEnumerator.h"

// Because the block is stored as a generic id, we must cast it back before we can call it.
static inline void TOFileSystemItemListCallBlock(id block, id observer, id changes) {
    TOFileSystemItemListNotificationBlock _block = (TOFileSystemItemListNotificationBlock)block;
    _block(observer, changes);
};

@interface TOFileSystemItemList () <TOFileSystemNotifying>

/** The UUID string of the directory backing this object */
@property (nonatomic, copy, readwrite) NSString *uuid;

/** A weak reference to the observer object we were created by. */
@property (nonatomic, weak, readwrite) TOFileSystemObserver *fileSystemObserver;

/** A writeable copy of the location of this directory */
@property (nonatomic, strong, readwrite) NSURL *directoryURL;

/** An dictionary of the items in this dictionary, stored by their UUID. */
@property (nonatomic, strong) NSMutableDictionary<NSString *, TOFileSystemItem *> *items;

/** An array of the item UUIDs, sorted in the order specified. */
@property (nonatomic, strong) NSMutableArray<NSString *> *sortedItems;

/** A set that holds all of the notification tokens generated by this list */
@property (nonatomic, strong) NSHashTable *notificationTokens;

@end

@implementation TOFileSystemItemList

- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL
                  fileSystemObserver:(TOFileSystemObserver *)observer
{
    if (self = [super init]) {
        _fileSystemObserver = observer;
        _directoryURL = directoryURL;
        _uuid = [directoryURL to_fileSystemUUID];
        [self commonInit];
    }
    
    return self;
}

- (void)commonInit
{
    // Create the file list stores
    _items = [NSMutableDictionary dictionary];
    _sortedItems = [NSMutableArray array];
}

- (void)buildItemsList
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fileManager to_fileSystemEnumeratorForDirectoryAtURL:_directoryURL];
    
    // Build a new list of files from what is currently on disk
    for (NSURL *url in enumerator) {
        TOFileSystemItem *item = [self.fileSystemObserver itemForFileAtURL:url];

        // Add the list to the item's store so it can notify of updates
        [item addToList:self];
        
        // Capture the item with its UUID in the dictionary
        _items[item.uuid] = item;
    }
    
    // Sort according to our current sort settings
    _sortedItems = _items.allKeys.mutableCopy;
    [self sortItemsList];
}

- (void)rebuildItemListForListingOrder
{
    if (self.sortedItems.count == 0) { return; }
    
    // Grab a copy of the current list
    NSArray *previousList = [self.sortedItems copy];
    
    // Sort the list to the new order
    [self sortItemsList];
    
    // Build a dictionary of all of the UUIDs so we can map the old
    // ordering to the new ordering, but use the hashing features of the
    // dictionary to avoid doing random lookup each time for each item
    NSMutableDictionary *newSortedItemsDict = [NSMutableDictionary dictionary];
    for (NSInteger i = 0; i < self.sortedItems.count; i++) {
        newSortedItemsDict[self.sortedItems[i]] = @(i);
    }
    
    // Loop through and build a list of indices for each moved cell.
    TOFileSystemItemListChanges *changes = [[TOFileSystemItemListChanges alloc] init];
    for (NSInteger i = 0; i < previousList.count; i++) {
        // Work out where the item in the new list went
        NSInteger newIndex = [newSortedItemsDict[previousList[i]] intValue];
        [changes addMovementWithSourceIndex:i destinationIndex:newIndex];
    }
    
    // Trigger the notification blocks to update any UI with this new order
    for (TOFileSystemNotificationToken *token in self.notificationTokens) {
        TOFileSystemItemListCallBlock(token.notificationBlock, self, changes);
    }
}

#pragma mark - Sorting Items -

- (NSComparator)sortComparator
{
    __weak typeof(self) weakSelf = self;
    return ^NSComparisonResult(NSString *firstUUID, NSString *secondUUID) {
        // Check if the UUID matches
        if ([firstUUID isEqualToString:secondUUID]) {
            return NSOrderedSame;
        }
        
        TOFileSystemItem *firstItem = weakSelf.items[firstUUID];
        TOFileSystemItem *secondItem = weakSelf.items[secondUUID];
        
        // If the order is flipped, swap around the two items
        if (self.isDescending) {
            TOFileSystemItem *tempItem = firstItem;
            firstItem = secondItem;
            secondItem = tempItem;
        }
        
        switch (weakSelf.listOrder) {
            case TOFileSystemItemListOrderAlphanumeric:
            {
                return [firstItem.name localizedStandardCompare:secondItem.name];
            }
            case TOFileSystemItemListOrderDate:
            {
                return [firstItem.modificationDate compare:secondItem.modificationDate];
            }
            default:
            {
                // File sizes always go descending by default.
                // Compare file names if the sizes match to keep clean ordering (Because folders are always 0)
                NSComparisonResult result = [@(secondItem.size) compare:@(firstItem.size)];
                if (result == NSOrderedSame) { return [firstItem.name localizedStandardCompare:secondItem.name]; }
                return result;
            }
        }
    };
}

- (void)sortItemsList
{
    // Sort all of the UUIDS
    [_sortedItems sortUsingComparator:self.sortComparator];
}

- (NSUInteger)sortedIndexForItemWithUUID:(NSString *)uuid
{
    return [self.sortedItems indexOfObject:uuid
                             inSortedRange:(NSRange){0, self.sortedItems.count}
                                   options:NSBinarySearchingInsertionIndex
                           usingComparator:self.sortComparator];
}

#pragma mark - External Item Access -

- (NSUInteger)count
{
    // Lazy-load the list when we query for the first time.
    if (self.sortedItems.count == 0) {
        [self buildItemsList];
    }
    
    return self.items.count;
}

- (TOFileSystemItem *)objectAtIndex:(NSUInteger)index
{
    return self.items[self.sortedItems[index]];
}

- (id)objectAtIndexedSubscript:(NSUInteger)index
{
    return self.items[self.sortedItems[index]];
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained _Nullable [_Nonnull])buffer
                                    count:(NSUInteger)len
{
    return [_items countByEnumeratingWithState:state
                                       objects:buffer
                                         count:len];
}

#pragma mark - Live Item Updating -

- (void)addItemWithUUID:(NSString *)uuid itemURL:(NSURL *)url
{
    // Skip if this item is already in the list
    if (self.items[uuid]) { return; }
    
    // Generate a new item and add it to our list
    TOFileSystemItem *item = [self.fileSystemObserver itemForFileAtURL:url];
    [item addToList:self];
    self.items[item.uuid] = item;
    
    // Work out where the item should go in our sorted list
    NSUInteger sortedIndex = [self sortedIndexForItemWithUUID:item.uuid];
    [self.sortedItems insertObject:item.uuid atIndex:sortedIndex];
    
    // Perform the broadcast to any observing objects that this update ocurred
    TOFileSystemItemListChanges *changes = [[TOFileSystemItemListChanges alloc] init];
    [changes addInsertionIndex:sortedIndex];
    for (TOFileSystemNotificationToken *token in self.notificationTokens) {
        TOFileSystemItemListCallBlock(token.notificationBlock, self, changes);
    }
}

- (void)removeItemWithUUID:(NSString *)uuid fileURL:(NSURL *)url
{
    // Verify the item is still here
    if (self.items[uuid] == nil) { return; }
    
    // Work out where the item is in the list
    NSInteger index = [self.sortedItems indexOfObject:uuid];
    NSAssert(index != NSNotFound, @"items and sortedItems should never be out of sync");
    
    // Un-assign the list
    [self.items[uuid] removeFromList];
    
    // Remove the item from both stores
    [self.items removeObjectForKey:uuid];
    [self.sortedItems removeObjectAtIndex:index];
    
    // Trigger the notification blocks
    TOFileSystemItemListChanges *changes = [[TOFileSystemItemListChanges alloc] init];
    [changes addDeletionIndex:index];
    
    for (TOFileSystemNotificationToken *token in self.notificationTokens) {
        TOFileSystemItemListCallBlock(token.notificationBlock, self, changes);
    }
}

- (void)itemDidRefreshWithUUID:(NSString *)uuid
{
    // Verify the item is still here
    if (self.items[uuid] == nil) { return; }
    
    // Create a changes object for the notification blocks
    TOFileSystemItemListChanges *changes = [[TOFileSystemItemListChanges alloc] init];
    
    // Work out where it is in the list
    NSInteger oldIndex = [self.sortedItems indexOfObject:uuid];
    
    // Work out where it should go in the list
    [self.sortedItems removeObjectAtIndex:oldIndex];
    NSInteger newIndex = [self sortedIndexForItemWithUUID:uuid];
    
    // Move it to the new location
    if (oldIndex != newIndex) {
        [self.sortedItems insertObject:uuid atIndex:newIndex];
        [changes addMovementWithSourceIndex:oldIndex destinationIndex:newIndex];
    }
    else {
        [self.sortedItems insertObject:uuid atIndex:oldIndex];
    }
    
    // Set the change object to reload the item
    [changes addModificationIndex:newIndex];
    
    // Broadcast the changes
    for (TOFileSystemNotificationToken *token in self.notificationTokens) {
        TOFileSystemItemListCallBlock(token.notificationBlock, self, changes);
    }
}

- (void)synchronizeWithDisk
{
    // After a scan and all present files have been verified, it's possible there
    // are some items lingering from files that were deleted.
    
    // Loop through every file in this list, and double-check it's still on disk
    TOFileSystemItemListChanges *changes = [[TOFileSystemItemListChanges alloc] init];
    for (NSInteger i = 0; i < self.sortedItems.count; i++) {
        TOFileSystemItem *item = self.items[self.sortedItems[i]];
        if (item.isDeleted) {
            [changes addDeletionIndex:i];
        }
    }
    
    // Skip if every file was accounted for
    if (changes.deletions.count == 0) { return; }
    
    // Remove all of the deleted files from the list
    for (NSNumber *deletedIndex in changes.deletions) {
        NSString *uuid = self.sortedItems[deletedIndex.intValue];
        [self.sortedItems removeObjectAtIndex:deletedIndex.intValue];
        [self.items removeObjectForKey:uuid];
    }
    
    // Broadcast the changes
    dispatch_async(dispatch_get_main_queue(), ^{
        for (TOFileSystemNotificationToken *token in self.notificationTokens) {
            TOFileSystemItemListCallBlock(token.notificationBlock, self, changes);
        }
    });
}

#pragma mark - Notification Token -

- (TOFileSystemNotificationToken *)addNotificationBlock:(TOFileSystemItemListNotificationBlock)block
{
    TOFileSystemNotificationToken *token = [TOFileSystemNotificationToken tokenWithObservingObject:self block:block];
    if (self.notificationTokens == nil) {
        self.notificationTokens = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory];
    }
    [self.notificationTokens addObject:token];
    return token;
}

- (void)removeNotificationToken:(TOFileSystemNotificationToken *)token
{
    [self.notificationTokens removeObject:token];
}

#pragma mark - Accessors -

- (void)setListOrder:(TOFileSystemItemListOrder)listOrder
{
    if (_listOrder == listOrder) { return; }
    _listOrder = listOrder;
    [self rebuildItemListForListingOrder];
}

- (void)setIsDescending:(BOOL)isDescending
{
    if (_isDescending == isDescending) { return; }
    _isDescending = isDescending;
    [self rebuildItemListForListingOrder];
}

- (BOOL)refreshWithURL:(NSURL *)directoryURL
{
    if (directoryURL == nil) { return NO; }
    
    BOOL hasChanges = NO;
    @synchronized (self) {
        if (self.directoryURL != directoryURL) {
            self.directoryURL = directoryURL;
            hasChanges = YES;
        }
    }
    
    return hasChanges;
}

#pragma mark - Debugging -

- (NSString *)description
{
    return [NSString stringWithFormat:@"url = '%@', uuid = '%@', listOrder = %ld, isDescending = %d, items = '%@'",
            _directoryURL,
            _uuid,
            (long)_listOrder,
            _isDescending,
            _items];
}

@end
