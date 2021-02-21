from django.urls import path
from . import views

urlpatterns = [
	path('', views.index, name='home'),
	path('cv-admin/', views.AdminView, name='admin'),
	path('cv-admin/addCurrency/', views.addCurrency, name='addCurrency'),
	path('cv-admin/update/<country_id>/', views.update, name='update'),
	path("login/", views.Connexion, name='login'),
	path("logout/", views.disconnect, name='logout'),
	path("register/", views.Register.as_view(), name='register'),
	path('step1/', views.step1, name='step1'),
	path('step2/', views.step2, name='step2'),
	path('requests/', views.requests, name='requests'),
	path('_Pmo_Px/<int:id>', views.validerRecu, name='recu'),
	path('_Qkld_mb/<int:id>', views.validerEnvoie, name='envoi')

]
