// @title           Reports API
// @version         1.0
// @description     Reports and Audit API.
// @host            localhost:9009
// @BasePath        /api/v1
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"

	_ "github.com/NorthstarEngineering/RAS-Backend/services/reports-api/docs"
	swaggerFiles "github.com/swaggo/files"
	ginSwagger "github.com/swaggo/gin-swagger"

	"github.com/NorthstarEngineering/RAS-Backend/services/reports-api/internal/reports"
	"github.com/gin-gonic/gin"
	"github.com/jmoiron/sqlx"
	_ "github.com/lib/pq"
)

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}

func main() {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		dbHost := getEnv("DB_HOST", "localhost")
		dbPort := getEnv("DB_PORT", "5432")
		dbName := getEnv("DB_NAME", "restaurant_db")
		dbUser := getEnv("DB_USER", "reports_app")
		dbPass := getEnv("DB_PASSWORD", "TestPassword123")
		dbURL = fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable", dbUser, dbPass, dbHost, dbPort, dbName)
	}

	db, err := sqlx.Connect("postgres", dbURL)
	if err != nil {
		log.Fatalf("failed to connect to database: %v", err)
	}
	defer db.Close()
	log.Println("✅ Connected to PostgreSQL")

	repo := reports.NewRepository(db)
	svc := reports.NewService(repo)
	handler := reports.NewHandler(svc)

	gin.SetMode(gin.ReleaseMode)
	router := gin.New()
	router.Use(gin.Logger(), gin.Recovery())

	// Middleware مؤقت لقراءة الـ Role والـ BranchID من الـ Header
	router.Use(func(c *gin.Context) {
		userRole := c.GetHeader("X-User-Role")
		branchID := c.GetHeader("X-Branch-ID")
		if userRole != "" {
			c.Set("user_role", userRole)
		}
		if branchID != "" {
			c.Set("branch_id", branchID)
		}
		c.Next()
	})

	router.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok", "service": "reports-api"})
	})

	router.GET("/swagger/*any", ginSwagger.WrapHandler(swaggerFiles.Handler))

	api := router.Group("/api/v1")
	handler.RegisterRoutes(api)

	port := getEnv("PORT", "9009")
	log.Printf("🚀 Reports API listening on :%s", port)
	if err := router.Run(":" + port); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
