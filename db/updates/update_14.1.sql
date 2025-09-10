DELETE FROM `system_settings` WHERE `system_settings`.`key_name` = 'SYSTEM_pubChem';
DROP TABLE `audit_log`;
ALTER TABLE `ingSuppliers` DROP `price_tag_start`, DROP `price_tag_end`;