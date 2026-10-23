USE app_test;
CREATE TABLE items (
    id INT PRIMARY KEY AUTO_INCREMENT,
    label VARCHAR(100) NOT NULL,
    quantity INT NOT NULL DEFAULT 0
) ENGINE=InnoDB;
CREATE TABLE item_audit (
    id INT PRIMARY KEY AUTO_INCREMENT,
    item_id INT NOT NULL,
    action VARCHAR(20) NOT NULL
) ENGINE=InnoDB;
CREATE VIEW available_items AS SELECT id, label FROM items WHERE quantity > 0;
CREATE TRIGGER item_insert AFTER INSERT ON items FOR EACH ROW
    INSERT INTO item_audit (item_id, action) VALUES (NEW.id, 'insert');
CREATE FUNCTION double_quantity(value INT) RETURNS INT DETERMINISTIC NO SQL RETURN value * 2;
CREATE PROCEDURE add_item(IN item_label VARCHAR(100)) INSERT INTO items (label) VALUES (item_label);
CREATE EVENT daily_item ON SCHEDULE EVERY 1 DAY DISABLE
    DO INSERT INTO items (label) VALUES ('event');
INSERT INTO items (label, quantity) VALUES ('áéí — teste', 3), ('second', 0);

CREATE DATABASE restored;
CREATE DATABASE has_table;
CREATE TABLE has_table.existing (id INT);
CREATE DATABASE has_routine;
CREATE PROCEDURE has_routine.existing() SELECT 1;
CREATE DATABASE has_event;
CREATE EVENT has_event.existing ON SCHEDULE EVERY 1 DAY DISABLE DO SELECT 1;
CREATE DATABASE partial_target;
