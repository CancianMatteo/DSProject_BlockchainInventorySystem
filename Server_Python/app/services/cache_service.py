from __future__ import annotations

from threading import RLock
from typing import TypedDict

from app.core.exceptions import AppError


class ItemInfo(TypedDict, total=False):
    """Item metadata stored alongside quantity."""
    id: str
    itemName: str
    brand: str
    itemType: str
    category: str
    quantity: int
    barcode: str | None


class ItemCatalogEntry(TypedDict, total=False):
    itemName: str
    brand: str
    itemType: str
    category: str
    barcode: str | None


class InventoryCache:
    def __init__(self) -> None:
        self._lock = RLock()
        self.items: dict[str, ItemInfo] = {}
        self.latest_block_hash: str | None = None
        self.latest_block_number: int = 0

    def reset(self) -> None:
        with self._lock:
            self.items = {}
            self.latest_block_hash = None
            self.latest_block_number = 0

    def simulate_changes(
        self,
        changes: dict[str, int],
        item_catalog: dict[str, ItemCatalogEntry] | None = None,
    ) -> dict[str, ItemInfo]:
        with self._lock:
            snapshot = dict(self.items)
            catalog = item_catalog or {}
            for item_id, delta in changes.items():
                default_item: ItemInfo = {
                    "id": item_id,
                    "itemName": item_id,
                    "brand": "",
                    "itemType": "",
                    "category": "Uncategorized",
                    "quantity": 0,
                    "barcode": None,
                }
                current = snapshot.get(
                    item_id,
                    default_item,
                )
                metadata = catalog.get(item_id, {})
                current_qty = current.get("quantity", 0)
                new_value = current_qty + delta
                if new_value < 0:
                    raise AppError(
                        "NEGATIVE_INVENTORY",
                        f"Item '{item_id}' would become negative",
                        status_code=422,
                    )
                if item_id not in snapshot and delta <= 0:
                    raise AppError(
                        "UNKNOWN_ITEM_NEGATIVE_DELTA",
                        f"Unknown item '{item_id}' can be added only with positive delta",
                        status_code=422,
                    )

                # Metadata can be updated by incoming catalog; legacy blocks remain valid.
                updated: ItemInfo = {
                    **current,
                    "id": item_id,
                    "itemName": (metadata.get("itemName") or current.get("itemName") or item_id),
                    "brand": (metadata.get("brand") or current.get("brand") or ""),
                    "itemType": (metadata.get("itemType") or current.get("itemType") or ""),
                    "category": (metadata.get("category") or current.get("category") or "Uncategorized"),
                    "barcode": metadata.get("barcode") if "barcode" in metadata else current.get("barcode"),
                    "quantity": new_value,
                }
                snapshot[item_id] = updated
            return snapshot

    def apply_changes(
        self,
        changes: dict[str, int],
        block_hash: str,
        block_number: int,
        item_catalog: dict[str, ItemCatalogEntry] | None = None,
    ) -> None:
        with self._lock:
            self.items = self.simulate_changes(changes, item_catalog)
            self.latest_block_hash = block_hash
            self.latest_block_number = block_number

    def get_inventory_list(self) -> list[ItemInfo]:
        """Return inventory as a list of item info dicts."""
        with self._lock:
            return list(self.items.values())


inventory_cache = InventoryCache()
